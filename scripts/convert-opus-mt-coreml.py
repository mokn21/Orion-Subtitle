#!/usr/bin/env python3
"""Export a MarianMT English->Arabic checkpoint as fixed-shape Core ML programs.

The Swift runtime calls the encoder once, then calls the decoder for each greedy
step. Fixed shapes keep the export deterministic for the first integration.
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
import torch
from transformers import MarianMTModel, MarianTokenizer
import coremltools as ct
import sentencepiece as spm
from tokenizers import Tokenizer
from tokenizers import models, normalizers, pre_tokenizers, decoders
from huggingface_hub import snapshot_download


def write_swift_tokenizer(spm_path: Path, vocab_path: Path, output: Path) -> None:
    """Create a pure-Swift Unigram tokenizer using Marian's vocab ID order."""
    vocab = json.loads(vocab_path.read_text(encoding='utf-8'))
    processor = spm.SentencePieceProcessor(model_file=str(spm_path))
    by_id = {index: token for token, index in vocab.items()}
    pairs = []
    for index in range(len(by_id)):
        token = by_id[index]
        piece_id = processor.piece_to_id(token)
        score = float(processor.get_score(piece_id)) if piece_id >= 0 else -20.0
        pairs.append((token, score))
    tokenizer = Tokenizer(models.Unigram(pairs, unk_id=vocab.get('<unk>', 0)))
    tokenizer.normalizer = normalizers.Sequence([normalizers.Nmt(), normalizers.NFKC()])
    tokenizer.pre_tokenizer = pre_tokenizers.Metaspace(replacement='▁', prepend_scheme='always')
    tokenizer.decoder = decoders.Metaspace(replacement='▁', prepend_scheme='always')
    output.mkdir(parents=True, exist_ok=True)
    tokenizer.save(str(output / 'tokenizer.json'))
    (output / 'tokenizer_config.json').write_text(json.dumps({
        'tokenizer_class': 'PreTrainedTokenizer',
        'model_type': 'marian',
        'unk_token': '<unk>',
        'eos_token': '</s>',
        'pad_token': '<pad>',
    }), encoding='utf-8')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', default='Helsinki-NLP/opus-mt-tc-big-en-ar')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-input-tokens', type=int, default=64)
    parser.add_argument('--max-output-tokens', type=int, default=64)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    tokenizer = MarianTokenizer.from_pretrained(args.model)
    snapshot = Path(snapshot_download(
        args.model,
        allow_patterns=['source.spm', 'target.spm', 'vocab.json'],
    ))
    write_swift_tokenizer(
        snapshot / 'source.spm',
        snapshot / 'vocab.json',
        args.output / 'source-tokenizer',
    )
    write_swift_tokenizer(
        snapshot / 'target.spm',
        snapshot / 'vocab.json',
        args.output / 'target-tokenizer',
    )
    for prefix in ('source-tokenizer', 'target-tokenizer'):
        folder = args.output / prefix
        shutil.copyfile(folder / 'tokenizer.json', args.output / f'{prefix}.json')
        shutil.copyfile(folder / 'tokenizer_config.json', args.output / f'{prefix}-config.json')
        shutil.rmtree(folder)
    model = MarianMTModel.from_pretrained(args.model).eval()
    model.config.use_cache = False

    input_ids = torch.ones((1, args.max_input_tokens), dtype=torch.int32)
    attention_mask = torch.ones((1, args.max_input_tokens), dtype=torch.int32)

    class Encoder(torch.nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base
        def forward(self, input_ids, attention_mask):
            return self.base.model.encoder(
                input_ids=input_ids.to(torch.long),
                attention_mask=attention_mask.to(torch.long),
                return_dict=False,
            )[0]

    class Decoder(torch.nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base
        def forward(self, decoder_input_ids, encoder_hidden_states, encoder_attention_mask):
            outputs = self.base.model.decoder(
                input_ids=decoder_input_ids.to(torch.long),
                attention_mask=torch.ones_like(decoder_input_ids, dtype=torch.long),
                encoder_hidden_states=encoder_hidden_states,
                encoder_attention_mask=encoder_attention_mask.to(torch.long),
                use_cache=False,
                return_dict=False,
            )[0]
            return self.base.lm_head(outputs)

    encoder = torch.jit.trace(Encoder(model), (input_ids, attention_mask), strict=False)
    decoder_ids = torch.ones((1, args.max_output_tokens), dtype=torch.int32)
    hidden = torch.zeros((1, args.max_input_tokens, model.config.d_model), dtype=torch.float32)
    decoder_mask = torch.ones((1, args.max_input_tokens), dtype=torch.int32)
    decoder = torch.jit.trace(Decoder(model), (decoder_ids, hidden, decoder_mask), strict=False)

    deployment = ct.target.iOS18
    encoder_ml = ct.convert(
        encoder,
        convert_to='mlprogram',
        minimum_deployment_target=deployment,
        inputs=[
            ct.TensorType(name='input_ids', shape=input_ids.shape, dtype=int),
            ct.TensorType(name='attention_mask', shape=attention_mask.shape, dtype=int),
        ],
        outputs=[ct.TensorType(name='encoder_hidden_states')],
    )
    encoder_ml.author = 'Helsinki-NLP / Orion Subtitles integration'
    encoder_ml.short_description = 'OPUS-MT English-Arabic encoder'
    encoder_ml.save(str(args.output / 'OpusMTEnglishArabicEncoder.mlpackage'))

    decoder_ml = ct.convert(
        decoder,
        convert_to='mlprogram',
        minimum_deployment_target=deployment,
        inputs=[
            ct.TensorType(name='decoder_input_ids', shape=decoder_ids.shape, dtype=int),
            ct.TensorType(name='encoder_hidden_states', shape=hidden.shape),
            ct.TensorType(name='encoder_attention_mask', shape=decoder_mask.shape, dtype=int),
        ],
        outputs=[ct.TensorType(name='logits')],
    )
    decoder_ml.author = 'Helsinki-NLP / Orion Subtitles integration'
    decoder_ml.short_description = 'OPUS-MT English-Arabic decoder'
    decoder_ml.save(str(args.output / 'OpusMTEnglishArabicDecoder.mlpackage'))

    (args.output / 'model-metadata.txt').write_text(
        f'model={args.model}\n'
        f'max_input_tokens={args.max_input_tokens}\n'
        f'max_output_tokens={args.max_output_tokens}\n'
        f'pad_token_id={tokenizer.pad_token_id}\n'
        f'eos_token_id={tokenizer.eos_token_id}\n'
        f'decoder_start_token_id={model.config.decoder_start_token_id}\n',
        encoding='utf-8',
    )


if __name__ == '__main__':
    main()
