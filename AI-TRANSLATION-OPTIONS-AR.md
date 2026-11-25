# خيارات ترجمة AI مجانية لـ Orion Subtitles

## الحالة الصادقة

لم يتم دمج نموذج AI خارجي داخل IPA حتى الآن. النسخة الحالية تستخدم Apple Translation فقط، مع إدارة جلسة واحدة، مهلة للطلبات، ورسائل عربية عند فشل الجلسة أو عدم توفر نموذج اللغة.

النموذج المفتوح الأنسب للاتجاه English → Arabic هو Helsinki-NLP/opus-mt-tc-big-en-ar. بطاقة النموذج تذكر أنه مخصص للترجمة من الإنجليزية إلى العربية، بترخيص CC-BY-4.0، وحجمه المعروض نحو 0.2B parameters. الرابط: https://huggingface.co/Helsinki-NLP/opus-mt-tc-big-en-ar

## القيود التقنية

النموذج المنشور بصيغة PyTorch/Safetensors وليس ملفًا جاهزًا للإضافة إلى تطبيق Swift. تشغيله داخل IPA يحتاج تحويلًا إلى Core ML أو استخدام runtime أصلي، وإضافة tokenizer وملفات النموذج. صفحة swift-transformers الرسمية توضح أن الحزمة توفر Hub وTokenizers وأدوات Core ML، وأن Core ML LanguageModel APIs تتطلب iOS 18 أو أحدث. الرابط: https://github.com/huggingface/swift-transformers

المستودع الرسمي لـ OPUS-MT يصف النماذج والخدمات ويفرض حفظ إسناد CC-BY-4.0 للنماذج. الرابط: https://github.com/Helsinki-NLP/Opus-MT

## لماذا لم أضع الاسم فقط داخل التطبيق؟

ملفات النموذج المنشورة ليست ملف Core ML جاهزًا للاستخدام في Swift. يلزم تحويل النموذج واختباره، أو دمج runtime كامل للتوليد. `swift-transformers` يوفر Tokenizers وHub وأدوات Models/Generation لـ Core ML، لكن واجهات `LanguageModel` تتطلب iOS 18 أو أحدث، كما أن أمثلة المشروع المنشورة تركز على نماذج Core ML جاهزة وليست تحويل Marian تلقائيًا.

لم أضع نموذجًا غير قابل للتشغيل داخل IPA، ولم أستخدم Hugging Face أو خدمة عامة بلا ضمان، ولم أضع مفتاح API. كما لم أعد بزمن أقل من ثانية قبل قياسه على iPad فعلي.

## Apple Translation

توثيق Apple يوضح أن Translation framework يدعم iPadOS 17.4+ ويتيح TranslationSession مخصصًا داخل التطبيق، مع فحص توفر اللغة. الرابط: https://developer.apple.com/documentation/translation

## فحص خيار السحابة المجاني

LibreTranslate مشروع مفتوح المصدر ويقدم واجهة `/translate`، لكن مواصفاته تجعل `api_key` اختياريًا من ناحية البروتوكول فقط، بينما إعدادات الخادم قد تجعل المفتاح مطلوبًا. كما أن النقاط العامة تتغير وقد تفرض حدودًا أو تمنع الاستخدام. لا يجوز وضع مفتاح داخل IPA، ولا يجوز إرسال نصوص ألعاب المستخدم إلى خادم عام بدون موافقة واضحة وسياسة خصوصية. لذلك لم أضع endpoint عامًا غير موثوق داخل التطبيق.

المصادر: https://libretranslate.com/docs/ و https://libretranslate.com/spec

## القرار الحالي

سيبقى Apple Translation موجودًا ولن أزيله. لن أصف OPUS-MT بأنه مدمج حتى يتم توفير ملف نموذج قابل للتشغيل واختبار ترجمة فعلية على iPad. المسار الصحيح التالي هو تحويل OPUS-MT إلى Core ML أو توفير خادم يملكه المستخدم، ثم ربطه عبر `TextTranslationService` مع Apple Translation كـ fallback واضح.
