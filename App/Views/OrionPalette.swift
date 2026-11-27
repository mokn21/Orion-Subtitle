import SwiftUI
import UIKit

/// Orion's four approved brand colours, adapted for the system appearance.
enum OrionPalette {
    private static func adaptive(light: UInt, dark: UInt, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let alpha = traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }

    static let background = adaptive(light: 0xF8F3D9, dark: 0x191B18)
    static let panel = adaptive(light: 0xEBE5C2, dark: 0x2B2E27)
    static let panelAlt = adaptive(light: 0xF8F3D9, dark: 0x22251F)
    static let cream = adaptive(light: 0x504B38, dark: 0xF8F3D9)
    static let muted = adaptive(light: 0x716B54, dark: 0xCDC7A6)
    static let olive = adaptive(light: 0xB9B28A, dark: 0xB9B28A)
    static let stroke = adaptive(light: 0x504B38, dark: 0xB9B28A, lightAlpha: 0.18, darkAlpha: 0.28)
    static let buttonText = Color(red: 80 / 255, green: 75 / 255, blue: 56 / 255)
}
