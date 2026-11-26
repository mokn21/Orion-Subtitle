import SwiftUI

#if canImport(Translation)
import Translation

struct AppleTranslationTaskModifier: ViewModifier {
    let bridge: AnyObject?

    func body(content: Content) -> some View {
        guard #available(iOS 18.0, *) else { return AnyView(content) }
        let typedBridge = bridge as? AppleTranslationBridge
        let translatedContent = content.translationTask(typedBridge?.configuration) { session in
            guard let typedBridge else { return }
            typedBridge.recordTranslationTaskClosureStarted()
            defer { typedBridge.recordTranslationTaskClosureEnded() }
            await typedBridge.run(session: session)
        }
        return AnyView(
            translatedContent.onAppear {
                // Do not mutate the observable bridge while SwiftUI is evaluating body.
                typedBridge?.recordModifierMounted()
            }
        )
    }
}
#else
struct AppleTranslationTaskModifier: ViewModifier {
    let bridge: AnyObject?
    func body(content: Content) -> some View { content }
}
#endif
