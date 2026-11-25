# Orion Subtitles external translation proxy

This Cloudflare Worker receives only OCR text from the iPad and calls Gemini `gemini-3.5-flash-lite` for English-to-Arabic translation. The Gemini key is a Worker secret and must never be placed in the IPA, this repository, or `wrangler.toml`.

## Required setup

1. Create a Gemini API key in Google AI Studio and keep it private.
2. Store it in the Worker as the `GEMINI_API_KEY` secret.
3. Deploy this Worker on a free Cloudflare Workers plan.
4. Put the deployed `/` URL followed by `/translate` into the app's `TRANSLATION_PROXY_URL` build setting.

The Worker rejects non-POST requests, accepts English-to-Arabic only, limits OCR text to 500 characters, and returns only `{ "translation": "..." }` on success. The `X-Orion-Client` header is an abuse-reduction signal, not a secret; anything shipped in an IPA can be extracted.

The app sends text, not the Remote Play image and not the PS5 credentials. If the proxy is unavailable, the app uses Apple Translation as its existing fallback when available.
