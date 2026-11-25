# تقرير تنفيذ Orion Subtitles — حالة الإصدار الحالي

## ما أصبح منفذًا داخل المشروع

يأخذ التطبيق إطارات `CVPixelBuffer` من مسار Remote Play الداخلي بعد فك ترميز الفيديو، ثم يمررها إلى Apple Vision OCR. يستخدم OCR اللغة المحفوظة من الإعدادات، ويدعم الإنجليزية أو الكشف التلقائي، ويستخدم منطقة normalized قابلة للتغيير.

تم فصل دورة OCR عن دورة الترجمة. وصول إطار جديد يلغي OCR السابق فقط. أما الترجمة التي بدأت بالفعل فتستمر ولا تُلغى تلقائيًا. لكل نتيجة رقم generation، ولا تُعرض نتيجة ترجمة قديمة بعد قبول جملة أحدث. النص المتكرر لا يعاد إرساله، والنصوص المترجمة تُحفظ في cache. عند الإيقاف تُلغى مهام OCR والترجمة وتُفرغ مواردها.

تم ربط Apple Translation الرسمي عبر SwiftUI `translationTask` و`TranslationSession` عندما تتوفر واجهاته على iPadOS 18 أو أحدث، مع فحص `LanguageAvailability` للزوج English → Arabic. حالات عدم توفر اللغة أو الحاجة إلى نماذج اللغة تظهر كخطأ واضح بدل ترجمة وهمية. بقي deployment target للمشروع iPadOS 17.0، وتُحرس واجهات Apple الأحدث بـ`@available`.

أصبح عرض الترجمة فوق بث Remote Play مرتبطًا بالنتيجة الفعلية وبإعدادات حجم الخط والمكان. بطاقة Live تبدأ أول كونسول محفوظ وتدخل جلسة Remote Play. بطاقة Independent Black تبدأ الجلسة نفسها وتدخل شاشة سوداء تعرض آخر ترجمة عربية والنص الإنجليزي وتستمر بالتحديث من نفس المنسق. وضع TV Mode ما زال ظاهرًا كـComing Soon ولا يدعي وظيفة غير موجودة.

أضيفت إعدادات محفوظة في `StreamSettings` للغة OCR، لغة الترجمة، منطقة الالتقاط، حجم الخط، مكان العرض، وفاصل فحص OCR. تُطبّق إعدادات المنطقة واللغة والفاصل داخل `StreamSession`، وتُطبّق إعدادات الحجم والمكان في العرض. تُحفظ عبر `SettingsStore` داخل UserDefaults.

## ما تم بناؤه وما لم يتم اختباره ميدانيًا

نجح Workflow رقم `44932911124` في بناء IPA، وفحص iPad-only وBundle ID، ورفع artifact `orion-subtitles-ipa`. هذا يثبت سلامة تجميع المشروع وتغليف IPA فقط.

لم يتوفر iPad أو PS5 فعلي في بيئة التنفيذ. لذلك لم أختبر فعليًا اتصال Remote Play، أو استخراج نص لعبة حقيقي، أو تنزيل نموذج English → Arabic، أو ظهور ترجمة عربية أثناء اللعب، أو متوسط زمن OCR والترجمة، أو إعادة الدخول إلى جلسة PS5 بعد الخروج. لا أصف هذه النتائج بأنها مختبرة ميدانيًا.

اختبار السحب المباشر لمنطقة OCR، وتتابع عدة جمل متغيرة، وسلوك تنزيل النماذج يحتاج تشغيل التطبيق على iPad حقيقي. الكود يمنع إلغاء الترجمة الجارية عند كل إطار، لكن لا يمكن إثبات سلوك Apple Translation أثناء تنزيل النماذج دون الجهاز والنظام المناسبين.

## الملفات والنسخة

شملت آخر دفعة `Models.swift` و`StreamSession.swift` و`OCRService.swift` و`TranslationCoordinator.swift` و`SettingsView.swift` و`StreamView.swift` و`ConsoleListView.swift` و`TranslationModesView.swift`. آخر commit البرمجي هو `d11f01a`، وآخر commit في المستودع بعد تحديث هذا التقرير سيكون موضحًا في GitHub.

## المراجع

[1]: https://developer.apple.com/documentation/translation "Apple Translation framework"
[2]: https://developer.apple.com/documentation/translation/translating-text-within-your-app "Apple custom translation with SwiftUI"
[3]: https://developer.apple.com/documentation/vision/recognizing-text-in-images "Apple Vision text recognition"
[4]: https://developer.apple.com/documentation/replaykit "Apple ReplayKit"
