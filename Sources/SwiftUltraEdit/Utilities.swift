import AppKit

// MARK: - 通用工具

func formatByteCount(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: bytes)
}

func formatHex(_ value: Int64, width: Int = 8) -> String {
    return String(format: "%0\(width)llX", value)
}

/// 把一行中的不可打印控制字符替换为可见符号，避免绘制异常
func sanitizeForDisplay(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    var out = String()
    out.reserveCapacity(s.count)
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x09:
            out.append("    ")               // Tab 展开为 4 空格
        case 0x00...0x1F, 0x7F:
            out.append("\u{FFFD}")
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

func alertError(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func promptString(title: String, message: String, defaultValue: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = defaultValue
    field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}

func confirmAction(title: String, message: String, okTitle: String = "继续") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: okTitle)
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
}
