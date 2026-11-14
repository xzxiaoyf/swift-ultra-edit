import AppKit

enum Theme {

    static var editorBackground: NSColor {
        return NSColor.textBackgroundColor
    }

    static var editorText: NSColor {
        return NSColor.textColor
    }

    static var gutterBackground: NSColor {
        return NSColor.controlBackgroundColor
    }

    static var gutterText: NSColor {
        return NSColor.tertiaryLabelColor
    }

    static var gutterTextActive: NSColor {
        return NSColor.labelColor
    }

    static var gutterDivider: NSColor {
        return NSColor.separatorColor
    }

    static var selectionFill: NSColor {
        return NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
    }

    static var currentLineFill: NSColor {
        return NSColor.labelColor.withAlphaComponent(0.05)
    }

    static var caret: NSColor {
        return NSColor.controlAccentColor
    }

    static var hexAddress: NSColor {
        return NSColor.systemTeal
    }

    static var hexASCII: NSColor {
        return NSColor.secondaryLabelColor
    }

    static var hexZero: NSColor {
        return NSColor.quaternaryLabelColor
    }

    static var deletedLineFill: NSColor {
        return NSColor.systemRed.withAlphaComponent(0.08)
    }

    static var modifiedLineMark: NSColor {
        return NSColor.systemOrange
    }

    /// 默认字号（接近 VSCode 的 14pt 观感）
    static let defaultFontSize: CGFloat = 14

    static func codeFont(size: CGFloat) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 正文段落样式：行距略放宽，接近 VSCode 的行高观感
    static func codeParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.22
        return p
    }

    // MARK: - 语法配色（随浅色/深色外观自动切换，取值参考 VSCode Light+ / Dark+）

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    static let syntaxKeyword = dynamic(NSColor(srgbRed: 0.00, green: 0.00, blue: 0.78, alpha: 1),
                                       NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1))
    static let syntaxType = dynamic(NSColor(srgbRed: 0.15, green: 0.50, blue: 0.60, alpha: 1),
                                    NSColor(srgbRed: 0.31, green: 0.79, blue: 0.69, alpha: 1))
    static let syntaxString = dynamic(NSColor(srgbRed: 0.64, green: 0.08, blue: 0.08, alpha: 1),
                                      NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1))
    static let syntaxComment = dynamic(NSColor(srgbRed: 0.00, green: 0.50, blue: 0.00, alpha: 1),
                                       NSColor(srgbRed: 0.42, green: 0.60, blue: 0.33, alpha: 1))
    static let syntaxNumber = dynamic(NSColor(srgbRed: 0.04, green: 0.53, blue: 0.35, alpha: 1),
                                      NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1))
    static let syntaxFunction = dynamic(NSColor(srgbRed: 0.47, green: 0.37, blue: 0.15, alpha: 1),
                                        NSColor(srgbRed: 0.86, green: 0.86, blue: 0.67, alpha: 1))
    static let syntaxVariable = dynamic(NSColor(srgbRed: 0.00, green: 0.06, blue: 0.50, alpha: 1),
                                        NSColor(srgbRed: 0.61, green: 0.86, blue: 1.00, alpha: 1))
    static let syntaxAttribute = dynamic(NSColor(srgbRed: 0.69, green: 0.00, blue: 0.86, alpha: 1),
                                         NSColor(srgbRed: 0.77, green: 0.53, blue: 0.75, alpha: 1))

    static func boldUIFont(size: CGFloat) -> NSFont {
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func uiFont(size: CGFloat) -> NSFont {
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }
}
