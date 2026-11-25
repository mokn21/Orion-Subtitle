
## تدقيق ما قبل الرفع الأخير

تمت إعادة كتابة `README.md` بالكامل ليصف iPadOS فقط. أزيلت تعليمات iPhone Duo وكل الإشارات إلى تشغيل المشروع على iPhone، وأصبحت التعليمات تشرح البناء السحابي وSideStore وPS5 وواجهات iPad.

أصبح `verify-ipad-ipa.sh` يتحقق فعليًا من وجود `CFBundleIdentifier`، وأنه غير فارغ، وبصيغة Bundle ID صحيحة، وأنه يطابق `com.orion.subtitles`. كما يرفض القيم غير الصالحة بدل طباعتها فقط. اختُبر ذلك بحالتي IPA اصطناعيتين: حالة صحيحة قُبلت، وحالة بمعرف غير صالح رُفضت.

تمت مراجعة Workflow ومساراته. checkout يستخدم `submodules: recursive`، وتوجد فحوص قبل البناء لملفات `ChiakiKit` والـbridge وسكربتات البناء ومجلدات chiaki-ng وMbed TLS وOpus. كما اجتازت السكربتات فحص Bash syntax.

هذه النتائج ثابتة ومحلية فقط. لم يُشغّل `xcodebuild` ولم يُنتج IPA حقيقي بعد، لأن الجهاز الحالي Linux ولا يحتوي Xcode أو iOS SDK. نجاح البناء الحقيقي سيُثبت فقط من نتيجة GitHub Actions، وبعدها يجب أن يظهر `PASS: iPad-only IPA` في السجل.
