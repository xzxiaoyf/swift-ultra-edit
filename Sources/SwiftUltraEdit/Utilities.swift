import AppKit

// MARK: - 通用工具

/// 分阶段计时（设置 SUE_BENCH=/path/file.log 时启用），用于定位加载卡顿
enum Bench {
    /// 启用条件：环境变量 SUE_BENCH 指定日志路径，或存在 /tmp/sue_bench.on 标记文件
    /// （通过访达 / open 启动时无法注入环境变量，故提供标记文件方式）
    static var path: String? {
        if let p = ProcessInfo.processInfo.environment["SUE_BENCH"] { return p }
        if FileManager.default.fileExists(atPath: "/tmp/sue_bench.on") { return "/tmp/sue_bench.log" }
        return nil
    }

    static func mark(_ label: String) {
        guard let p = path else { return }
        let text = String(format: "%.3f %@\n", Date().timeIntervalSince1970, label)
        if let handle = FileHandle(forWritingAtPath: p) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: p))
        }
    }

    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard path != nil else { return body() }
        let t0 = Date()
        let result = body()
        let ms = Date().timeIntervalSince(t0) * 1000
        mark(String(format: "%@ 耗时 %.1f ms", label, ms))
        return result
    }

    /// 主线程心跳：每秒尝试一次主队列派发，记录响应延迟，用于判断界面是否卡死
    static func startWatchdog() {
        guard path != nil else { return }
        DispatchQueue.global().async {
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                let sent = Date()
                DispatchQueue.main.async {
                    let lag = Date().timeIntervalSince(sent) * 1000
                    mark(String(format: "心跳 主线程响应延迟 %.0f ms", lag))
                }
            }
        }
    }
}

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

/// 判断文本中是否存在超长行（提前退出，避免全文统计）。
/// 用于识别"没有换行"的大文件——此类文件若按不换行排版，
/// NSTextView 会被撑成数百万点宽，导致界面长时间无响应。
func textHasLineLongerThan(_ text: String, limit: Int) -> Bool {
    guard limit > 0 else { return false }
    var run = 0
    for scalar in text.unicodeScalars {
        if scalar == "\n" || scalar == "\r" {
            run = 0
        } else {
            run += 1
            if run > limit { return true }
        }
    }
    return false
}

/// 文本中最长行的字符数（用于状态提示，最多扫描 limit 个字符即退出）
func textLongestLineLength(_ text: String) -> Int {
    var longest = 0
    var run = 0
    for scalar in text.unicodeScalars {
        if scalar == "\n" || scalar == "\r" {
            longest = max(longest, run)
            run = 0
        } else {
            run += 1
        }
    }
    return max(longest, run)
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
