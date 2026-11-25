import SwiftUI

#if canImport(Translation)
import Translation

struct AppleTranslationTaskModifier: ViewModifier {
    let bridge: AnyObject?

    func body(content: Content) -> some View {
        guard #available(iOS 18.0, *) else { return AnyView(content) }
        let typedBridge = bridge as? AppleTranslationBridge
        if let typedBridge {
            typedBridge.recordModifierMounted()
        }
        return AnyView(
            content.translationTask(typedBridge?.configuration) { session in
                guard let typedBridge else { return }
                if #available(iOS 18.0, *) {
                    typedBridge.recordTranslationTaskClosureStarted()
                    defer { typedBridge.recordTranslationTaskClosureEnded() }
                    await typedBridge.run(session: session)
                }
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
