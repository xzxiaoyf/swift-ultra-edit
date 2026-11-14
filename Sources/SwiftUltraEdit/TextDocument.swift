import Foundation

enum NewlineStyle: String {
    case lf   = "\n"
    case crlf = "\r\n"
    case cr   = "\r"

    var displayName: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }
}

/// 大文件文本文档：不把全文载入内存，按行范围按需读取；
/// 编辑以「行」为单位记录在覆盖层，保存时流式重写文件。
final class TextDocument {

    let url: URL
    private(set) var encoding: TextEncodingKind
    let fileSize: Int64
    let index: LineIndex
    private(set) var newlineStyle: NewlineStyle
    private(set) var hasBOM: Bool

    private let readHandle: FileHandle?

    // 编辑覆盖层
    private(set) var lineEdits: [Int: String] = [:]     // 单行替换
    private(set) var deletedLines: Set<Int> = []        // 删除行
    private(set) var appendedLines: [String] = []       // 追加到文件末尾的行
    private(set) var encodingChanged = false

    // 行文本缓存
    private var lineCache: [Int: String] = [:]
    private var cacheKeys: [Int] = []
    private let cacheLimit = 6000

    var isDirty: Bool {
        return !lineEdits.isEmpty || !deletedLines.isEmpty || !appendedLines.isEmpty || encodingChanged
    }

    var displayLineCount: Int { index.totalLines + appendedLines.count }

    var editSummary: String {
        var parts: [String] = []
        if !lineEdits.isEmpty { parts.append("改 \(lineEdits.count) 行") }
        if !deletedLines.isEmpty { parts.append("删 \(deletedLines.count) 行") }
        if !appendedLines.isEmpty { parts.append("增 \(appendedLines.count) 行") }
        if encodingChanged { parts.append("编码变更") }
        return parts.joined(separator: " · ")
    }

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.url = url
        self.readHandle = handle
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        self.fileSize = size

        let detected = EncodingDetector.detect(url: url)
        self.encoding = detected.kind
        self.hasBOM = detected.hasBOM
        self.newlineStyle = EncodingDetector.detectNewline(url: url)
        self.index = LineIndex(url: url, fileSize: size)
    }

    func buildIndex(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.index.build()
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - 读取

    private func readBytes(_ range: Range<Int64>) -> Data {
        guard range.count > 0, let h = readHandle else { return Data() }
        do {
            try h.seek(toOffset: UInt64(range.lowerBound))
            return (try h.read(upToCount: range.count)) ?? Data()
        } catch {
            return Data()
        }
    }

    /// 原始行文本（不含行尾换行符），受编码解码影响
    func rawLineText(_ line: Int) -> String {
        guard let range = index.byteRange(ofLine: line) else { return "" }
        var data = readBytes(range)
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        guard !data.isEmpty else { return "" }
        return EncodingCodec.fastDecode(data, as: encoding) ?? "\u{FFFD}"
    }

    /// 展示用行文本（考虑覆盖层编辑）
    func lineText(_ line: Int) -> String {
        if line >= index.totalLines {
            let i = line - index.totalLines
            return (i >= 0 && i < appendedLines.count) ? appendedLines[i] : ""
        }
        if let edit = lineEdits[line] { return edit }
        if deletedLines.contains(line) { return "" }
        if let cached = lineCache[line] { return cached }
        let text = rawLineText(line)
        lineCache[line] = text
        cacheKeys.append(line)
        if cacheKeys.count > cacheLimit {
            lineCache.removeAll(keepingCapacity: true)
            cacheKeys.removeAll(keepingCapacity: true)
        }
        return text
    }

    func isLineDeleted(_ line: Int) -> Bool { deletedLines.contains(line) }
    func isLineEdited(_ line: Int) -> Bool { lineEdits[line] != nil }

    /// 读取行的原始字节（十六进制视图可能复用）
    func rawLineBytes(_ line: Int) -> Data {
        guard let range = index.byteRange(ofLine: line) else { return Data() }
        return readBytes(range)
    }

    // MARK: - 编辑

    func setLine(_ line: Int, text: String) {
        if line >= index.totalLines {
            let i = line - index.totalLines
            guard i >= 0 && i < appendedLines.count else { return }
            if appendedLines[i] == text { return }
            appendedLines[i] = text
            return
        }
        if deletedLines.contains(line) { deletedLines.remove(line) }
        if text == rawLineText(line) {
            lineEdits.removeValue(forKey: line)
        } else {
            lineEdits[line] = text
        }
        lineCache.removeValue(forKey: line)
    }

    func deleteLine(_ line: Int) {
        if line >= index.totalLines {
            let i = line - index.totalLines
            if i >= 0 && i < appendedLines.count { appendedLines.remove(at: i) }
            return
        }
        lineEdits.removeValue(forKey: line)
        deletedLines.insert(line)
    }

    func restoreLine(_ line: Int) {
        deletedLines.remove(line)
        lineEdits.removeValue(forKey: line)
        lineCache.removeValue(forKey: line)
    }

    func appendLine(_ text: String) {
        if text.isEmpty { return }
        appendedLines.append(text)
    }

    func setEncoding(_ kind: TextEncodingKind) {
        guard kind != encoding else { return }
        encoding = kind
        encodingChanged = true
        lineCache.removeAll(keepingCapacity: true)
        cacheKeys.removeAll(keepingCapacity: true)
    }

    func setNewlineStyle(_ style: NewlineStyle) {
        newlineStyle = style
    }

    // MARK: - 保存

    /// 流式重写。targetURL 为 nil 时覆盖原文件。
    func save(to targetURL: URL? = nil, progress: ((Double) -> Void)? = nil) throws {
        let target = targetURL ?? url
        let isSameFile = target.standardizedFileURL == url.standardizedFileURL
        let total = max(1, index.totalLines)

        if !encodingChanged && isSameFile && lineEdits.isEmpty && deletedLines.isEmpty && appendedLines.isEmpty {
            return
        }

        let tmpURL = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).swiftedit-\(UUID().uuidString.prefix(6)).tmp")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmpURL) else {
            throw NSError(domain: "SwiftUltraEdit", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件 \(tmpURL.path)"])
        }

        let bytesPerUnit: Int64 = 1 << 20
        func writeRaw(_ range: Range<Int64>) throws {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let end = min(cursor + bytesPerUnit, range.upperBound)
                let data = readBytes(cursor..<end)
                if data.isEmpty { break }
                try out.write(contentsOf: data)
                cursor += Int64(data.count)
            }
        }

        let nlBytes = newlineStyle.rawValue.data(using: .ascii) ?? Data([0x0A])
        let writeBOM = encoding.alwaysWritesBOM || (hasBOM && !encoding.bomBytes.isEmpty)

        do {
            if writeBOM {
                try out.write(contentsOf: Data(encoding.bomBytes))
            }

            if !encodingChanged && isSameFile {
                // 快速路径：未编辑的连续行按原始字节整体拷贝，保证零转码损失
                var runStart: Int64? = nil
                for line in 0..<index.totalLines {
                    let modified = lineEdits[line] != nil || deletedLines.contains(line)
                    if modified {
                        if let rs = runStart, let range = index.byteRange(ofLine: line) {
                            try writeRaw(rs..<range.lowerBound)
                        }
                        runStart = nil
                        if let text = lineEdits[line] {
                            var bytes = EncodingCodec.encode(text, as: encoding) ?? Data()
                            bytes.append(nlBytes)
                            try out.write(contentsOf: bytes)
                        }
                    } else if runStart == nil {
                        runStart = index.byteRange(ofLine: line)?.lowerBound
                    }
                    if line % 20000 == 0 { progress?(Double(line) / Double(total)) }
                }
                if let rs = runStart {
                    try writeRaw(rs..<fileSize)
                }
            } else {
                // 转码路径：逐行解码后按新编码写出
                for line in 0..<index.totalLines {
                    if deletedLines.contains(line) { continue }
                    // 末尾空行（文件以换行结尾产生的虚拟行）不重复写出换行
                    if line == index.totalLines - 1,
                       let r = index.byteRange(ofLine: line), r.count == 0 { continue }
                    let text = lineEdits[line] ?? rawLineText(line)
                    var bytes = EncodingCodec.encode(text, as: encoding) ?? Data()
                    bytes.append(nlBytes)
                    try out.write(contentsOf: bytes)
                    if line % 5000 == 0 { progress?(Double(line) / Double(total)) }
                }
            }

            for line in appendedLines {
                var bytes = EncodingCodec.encode(line, as: encoding) ?? Data()
                bytes.append(nlBytes)
                try out.write(contentsOf: bytes)
            }

            try out.close()

            if FileManager.default.fileExists(atPath: target.path) && isSameFile {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmpURL)
            } else {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: tmpURL, to: target)
            }
            progress?(1.0)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }
}
