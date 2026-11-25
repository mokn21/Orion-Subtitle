# Orion Subtitles — حالة التطوير والقيود التقنية

## النتيجة قبل إضافة OCR والترجمة

المستودع الحالي يحتوي على تطبيق Remote Play يعمل بنواة ChiakiKit، وفك ترميز الفيديو موجود في `VideoDecoder`، ثم تمرر الإطارات المفكوكة إلى `MetalRenderer.display(CVPixelBuffer)`. لكنه لا يحتوي حاليًا على ReplayKit أو Broadcast Upload Extension أو Vision OCR أو Translation framework أو طبقة ترجمة عربية.

لذلك لا يصح القول إن ميزة مشاركة الشاشة موجودة أو إن OCR يعمل حاليًا. يجب أن يبدأ التطوير من نقطة الإطار الموجودة داخل Remote Play.

## تصحيح مهم في متطلب التقاط الشاشة

على iPadOS لا يستطيع تطبيق عادي أن يقرأ بحرية شاشة تطبيق آخر ثم يرسم ترجمة فوقه كـsystem-wide overlay. ReplayKit مخصص لتسجيل أو بث الشاشة ضمن الآليات التي يسمح بها النظام، وواجهات ReplayKit القديمة التي كانت تُستخدم للبث مصنفة Deprecated في توثيق Apple الحالي. كما أن `RPScreenRecorder` يصف التقاط فيديو وصوت التطبيق، وليس منح Orion صلاحية عامة لقراءة كل تطبيق آخر.

البديل المدعوم والأقرب لهدف Orion هو معالجة إطارات Remote Play التي يستقبلها Orion نفسه. هذه الإطارات هي صورة اللعبة داخل التطبيق، ولذلك يمكن قص منطقة النص منها وتشغيل Vision OCR محليًا دون تصوير تطبيق آخر أو إرسال الإطارات إلى خادم خارجي. هذا يحافظ على هدف تشغيل اللعبة داخل Orion ويمنح OCR المصدر الصحيح.

إذا أراد المستخدم ترجمة تطبيق iPad آخر، فالبديل الواقعي هو استخدام ReplayKit فقط عندما يبدأ المستخدم broadcast يدعمه النظام، أو استخدام شاشة Orion المستقلة مع مصدر إطارات مدعوم. لا نعد بعرض فوق تطبيق آخر ولا نضيف overlay غير مسموح به.

## خطة التنفيذ الواقعية

المرحلة الأولى هي إضافة نموذج `TranslationMode` إلى الشاشة الرئيسية بثلاثة خيارات: Live Remote Play Translation، وBlack Translation Screen، وTV Mode — Coming Soon. الخيار الثالث واجهة فقط ولا يحتوي وظيفة تقنية.

المرحلة الثانية هي تمرير نسخة منخفضة التكرار من `CVPixelBuffer` من `StreamSession` إلى خدمة OCR، مع الحفاظ على مسار `MetalRenderer` دون انتظار OCR. تستخدم الخدمة منطقة normalized قابلة للتحريك والتغيير، وتنفذ `VNRecognizeTextRequest` على المسار السريع مع اللغة الإنجليزية، وتمنع معالجة الإطارات المتطابقة.

المرحلة الثالثة هي إضافة طبقة ترجمة مستقلة. على iPadOS 17.4 أو أحدث يمكن تجربة Apple Translation عبر `TranslationSession` بعد التحقق من توفر زوج اللغات. يجب أن تكون الطبقة قابلة للاستبدال، حتى لا نضع API مدفوعًا أو مفتاحًا سريًا في التطبيق. ستحتوي على cache، وإلغاء الطلب القديم عند وصول نص أحدث، ومنع ترجمة النص نفسه مرة أخرى.

المرحلة الرابعة هي واجهة الشاشة السوداء، مع النص العربي الحالي، والنص الإنجليزي السابق، وسجل اختياري، وحجم خط قابل للتعديل، ومنطقة OCR قابلة للتحريك. لن تدعي هذه الشاشة التقاط تطبيقات أخرى ما لم يقدم iPadOS مصدرًا مدعومًا.

المرحلة الخامسة هي القياس. يسجل النظام زمن وصول الإطار، وزمن OCR، وزمن الترجمة، وزمن ظهور النتيجة. لا يوصف الأداء بأنه فوري قبل وجود قياسات فعلية على iPad.

## المصادر الرسمية

[1]: https://developer.apple.com/documentation/replaykit "Apple ReplayKit documentation"
[2]: https://developer.apple.com/documentation/replaykit/rpscreenrecorder "Apple RPScreenRecorder documentation"
[3]: https://developer.apple.com/documentation/replaykit/rpbroadcastactivityviewcontroller "Apple broadcast activity documentation"
[4]: https://developer.apple.com/documentation/vision/recognizing-text-in-images "Apple Vision text recognition documentation"
[5]: https://developer.apple.com/documentation/translation "Apple Translation framework documentation"
