import UIKit

// C6: 与安卓版一炁键盘（微信输入法风格）一致的浅色 / 深色配色，自动跟随系统深浅色切换。
enum KeyboardTheme {
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            color(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    static let background = dynamic(light: 0xE4E6EB, dark: 0x1E1E20)
    static let keyBack = dynamic(light: 0xFFFFFF, dark: 0x4A4A4D)
    static let keyHighlight = dynamic(light: 0xC8CDD6, dark: 0x343437)
    static let fnBack = dynamic(light: 0xC8CDD6, dark: 0x343437)
    static let fnHighlight = dynamic(light: 0xB8BEC8, dark: 0x2A2A2D)
    static let accentBack = dynamic(light: 0x2FB36D, dark: 0x2BAA66)
    static let accentText = UIColor.white
    static let text = dynamic(light: 0x1F1F1F, dark: 0xF5F5F7)
    static let hint = dynamic(light: 0x8A8A8E, dark: 0xA6A6AC)
    static let candidateHighlight = dynamic(light: 0x2FB36D, dark: 0x3CC87D)
    static let pillBack = dynamic(light: 0xFFFFFF, dark: 0x2E2E30)
}
