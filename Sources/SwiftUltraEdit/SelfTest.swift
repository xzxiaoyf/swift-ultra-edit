import AppKit

/// 命令行自检：验证行索引、编码探测、编辑保存、十六进制改写等核心逻辑。
/// 用法：SwiftUltraEdit --selftest
enum SelfTest {

    private static var failures = 0
    private static var passes = 0

    private static func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passes += 1
            print("  PASS  \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name) \(detail.isEmpty ? "" : "-> \(detail)")")
        }
    }

    static func run() -> Int32 {
        print("SwiftUltraEdit 自检开始")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sue-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        testLineIndex(tmpDir)
        testEncoding(tmpDir)
        testTextDocumentEdit(tmpDir)
        testHexSource(tmpDir)
        testLargeFile()
        testSyntaxHighlighting()

        print("---------------------------------------")
        print("通过 \(passes) 项，失败 \(failures) 项")
        try? FileManager.default.removeItem(at: tmpDir)
        return failures == 0 ? 0 : 1
    }

    // MARK: - 行索引

    private static func testLineIndex(_ dir: URL) {
        print("\n[行索引]")
        let url = dir.appendingPathComponent("lines.txt")
        var content = ""
        for i in 0..<5000 {
            content += "第\(i)行 content-\(i)\n"
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let index = LineIndex(url: url, fileSize: size, stride: 128)
        index.build()

        check(index.built, "索引构建完成")
        check(index.totalLines == 5001, "行数与预期一致（含末尾空行）", "实际 \(index.totalLines)")

        let first = index.byteRange(ofLine: 0)
        check(first?.lowerBound == 0, "第 1 行起始偏移为 0")

        // 用独立解析结果校验每一行边界
        let bytes = [UInt8](FileManager.default.contents(atPath: url.path) ?? Data())
        var expectedStarts: [Int] = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A {
            expectedStarts.append(i + 1)
        }
        check(expectedStarts.count == index.totalLines, "换行数量一致",
              "解析 \(expectedStarts.count) / 索引 \(index.totalLines)")

        var mismatch = 0
        for line in [0, 1, 127, 128, 129, 255, 1000, 4095, 4998, 4999] {
            guard let range = index.byteRange(ofLine: line), line < expectedStarts.count else {
                mismatch += 1
                continue
            }
            if range.lowerBound != Int64(expectedStarts[line]) { mismatch += 1 }
            if line + 1 < expectedStarts.count, range.upperBound != Int64(expectedStarts[line + 1]) { mismatch += 1 }
        }
        check(mismatch == 0, "抽样行边界正确", "\(mismatch) 处不一致")

        var badReverse = 0
        for line in [0, 200, 1024, 3000, 4999] {
            guard let off = index.offset(ofLine: line) else { badReverse += 1; continue }
            if index.lineNumber(forOffset: off) != line { badReverse += 1 }
        }
        check(badReverse == 0, "偏移反查行号正确", "\(badReverse) 处不一致")
    }

    // MARK: - 编码

    private static func testEncoding(_ dir: URL) {
        print("\n[编码探测]")

        let gbkURL = dir.appendingPathComponent("gbk.txt")
        let gbkText = "简体中文 GB18030 编码检测，第二行。"
        try? gbkText.data(using: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString))))?.write(to: gbkURL)
        let gbk = EncodingDetector.detect(url: gbkURL)
        check(gbk.kind == .gb18030, "GB18030 识别", "实际 \(gbk.kind.displayName)")
        if let data = try? Data(contentsOf: gbkURL) {
            let decoded = EncodingCodec.decode(data, as: .gb18030)
            check(decoded == gbkText, "GB18030 解码正确")
        }

        let u16URL = dir.appendingPathComponent("u16.txt")
        try? (Data([0xFF, 0xFE]) + "UTF16 测试内容".data(using: .utf16LittleEndian)!).write(to: u16URL)
        let u16 = EncodingDetector.detect(url: u16URL)
        check(u16.kind == .utf16LE && u16.hasBOM, "UTF-16LE BOM 识别",
              "\(u16.kind.displayName) bom=\(u16.hasBOM)")
        if let data = try? Data(contentsOf: u16URL) {
            check(EncodingCodec.decode(data, as: .utf16LE) == "UTF16 测试内容", "UTF-16LE 解码正确")
        }

        let bomURL = dir.appendingPathComponent("bom.txt")
        try? (Data([0xEF, 0xBB, 0xBF]) + "带 BOM 的 UTF-8".data(using: .utf8)!).write(to: bomURL)
        let bom = EncodingDetector.detect(url: bomURL)
        check(bom.kind == .utf8BOM && bom.hasBOM, "UTF-8 BOM 识别")
        if let data = try? Data(contentsOf: bomURL) {
            check(EncodingCodec.decode(data, as: .utf8BOM) == "带 BOM 的 UTF-8", "BOM 解码不含多余字符")
        }

        let asciiURL = dir.appendingPathComponent("ascii.txt")
        try? "plain ascii text\n".write(to: asciiURL, atomically: true, encoding: .utf8)
        check(EncodingDetector.detect(url: asciiURL).kind == .utf8, "纯 ASCII 识别为 UTF-8")

        let bin = Data((0..<4096).map { UInt8($0 % 256) })
        check(EncodingDetector.looksBinary(bin), "二进制内容可识别")

        // 往返
        let sample = "中文English混合123"
        for kind in [TextEncodingKind.utf8, .gb18030, .utf16LE, .big5] {
            if let data = EncodingCodec.encode(sample, as: kind) {
                check(EncodingCodec.decode(data, as: kind) == sample, "\(kind.displayName) 往返一致")
            } else {
                check(false, "\(kind.displayName) 编码失败")
            }
        }

        // 换行风格
        let crlfURL = dir.appendingPathComponent("crlf.txt")
        try? "a\r\nb\r\nc\r\n".write(to: crlfURL, atomically: true, encoding: .utf8)
        check(EncodingDetector.detectNewline(url: crlfURL) == .crlf, "CRLF 识别")

        let lfURL = dir.appendingPathComponent("lf.txt")
        try? "a\nb\nc\n".write(to: lfURL, atomically: true, encoding: .utf8)
        check(EncodingDetector.detectNewline(url: lfURL) == .lf, "LF 识别")
    }

    // MARK: - 文本编辑与保存

    private static func testTextDocumentEdit(_ dir: URL) {
        print("\n[大文件模式编辑保存]")
        let url = dir.appendingPathComponent("edit.txt")
        let original = (0..<300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try? original.write(to: url, atomically: true, encoding: .utf8)

        guard let doc = TextDocument(url: url) else {
            check(false, "TextDocument 初始化")
            return
        }
        doc.index.build()
        check(doc.index.totalLines == 301, "打开行数正确（含末尾空行）", "\(doc.index.totalLines)")

        doc.setLine(1, text: "line 1 (edited)")
        doc.deleteLine(5)
        doc.appendLine("appended tail")

        check(doc.isDirty, "修改后标记为脏")

        do {
            try doc.save()
        } catch {
            check(false, "保存无异常", error.localizedDescription)
            return
        }

        let result = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = result.components(separatedBy: "\n")
        check(lines.count == 301, "保存后行数正确", "实际 \(lines.count)")
        check(lines[1] == "line 1 (edited)", "替换行写入正确", "实际 \(lines[1])")
        check(lines[5] == "line 6", "删除行后内容前移", "实际 \(lines[5])")
        check(result.contains("appended tail"), "追加行写入正确")
        check(lines[0] == "line 0" && lines[2] == "line 2", "未修改行保持原样")

        // 重新打开验证索引与磁盘一致
        if let doc2 = TextDocument(url: url) {
            doc2.index.build()
            check(doc2.index.totalLines == 301, "重开行数一致", "\(doc2.index.totalLines)")
            check(doc2.lineText(1) == "line 1 (edited)", "重开读取内容一致")
        }
    }

    // MARK: - 十六进制

    private static func testHexSource(_ dir: URL) {
        print("\n[十六进制读写]")
        let url = dir.appendingPathComponent("hex.bin")
        var data = Data()
        for i in 0..<1024 { data.append(UInt8(i % 256)) }
        try? data.write(to: url)

        guard let src = HexFileSource(url: url) else {
            check(false, "HexFileSource 初始化")
            return
        }
        check(src.size == 1024, "文件大小读取正确")
        check(src.totalRows == 64, "行数计算正确", "\(src.totalRows)")
        check(src.byte(at: 0) == 0x00, "首个字节为 0x00")
        check(src.byte(at: 255) == 0xFF, "跨缓存边界读取正确", "\(src.byte(at: 255))")

        src.setByte(0xAB, at: 10)
        src.setByte(0xCD, at: 1000)
        check(src.isDirty && src.changeCount == 2, "修改计数正确")

        do {
            try src.save()
        } catch {
            check(false, "十六进制保存无异常", error.localizedDescription)
            return
        }

        let after = [UInt8](FileManager.default.contents(atPath: url.path) ?? Data())
        check(after.count == 1024, "保存后大小不变")
        check(after[10] == 0xAB, "偏移 10 写入正确")
        check(after[1000] == 0xCD, "偏移 1000 写入正确")
        check(after[11] == 11, "相邻字节未被破坏")
    }

    // MARK: - 大文件

    private static func testLargeFile() {
        print("\n[大文件性能]")
        let path = "/tmp/sue_test/big.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            print("  SKIP  未找到 \(path)")
            return
        }
        let url = URL(fileURLWithPath: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        print("  文件大小: \(formatByteCount(size))")

        let index = LineIndex(url: url, fileSize: size)
        let t0 = Date()
        index.build()
        let elapsed = Date().timeIntervalSince(t0)
        check(index.built, "大文件索引构建完成")
        print("  索引耗时: \(String(format: "%.2f", elapsed)) 秒，行数: \(index.totalLines)，锚点数: \(index.anchors.count)")

        let t1 = Date()
        let mid = index.totalLines / 2
        _ = index.byteRange(ofLine: mid)
        let randomAccess = Date().timeIntervalSince(t1)
        check(randomAccess < 1.0, "随机行定位耗时低于 1 秒",
              String(format: "%.3f 秒", randomAccess))

        let doc = TextDocument(url: url)
        check(doc?.encoding == .utf8, "大文件编码识别为 UTF-8", doc?.encoding.displayName ?? "nil")
        if let d = doc {
            d.index.build()
            let t2 = Date()
            let text = d.rawLineText(mid)
            let readElapsed = Date().timeIntervalSince(t2)
            check(!text.isEmpty, "单行读取非空")
            check(readElapsed < 0.5, "单行读取耗时低于 0.5 秒", String(format: "%.3f 秒", readElapsed))
        }
    }

    // MARK: - 语法高亮

    private static func kind(of needle: String, in text: String, tokens: [SyntaxToken]) -> TokenKind? {
        let ns = text as NSString
        let r = ns.range(of: needle)
        guard r.location != NSNotFound else { return nil }
        for t in tokens where t.range.location <= r.location && r.location < t.range.location + t.range.length {
            return t.kind
        }
        return nil
    }

    private static func testSyntaxHighlighting() {
        print("\n[语法高亮]")

        check(SyntaxLanguage.detect(url: URL(fileURLWithPath: "/tmp/a.py")) == .python, "探测 .py 为 Python")
        check(SyntaxLanguage.detect(url: URL(fileURLWithPath: "/tmp/a.php")) == .php, "探测 .php 为 PHP")
        check(SyntaxLanguage.detect(url: URL(fileURLWithPath: "/tmp/a.sh")) == .shell, "探测 .sh 为 Shell")
        check(SyntaxLanguage.detect(url: URL(fileURLWithPath: "/tmp/a.unknown")) == .none, "未知扩展名回落纯文本")
        check(SyntaxLanguage.detectShebang("#! /usr/bin/env python3\nprint(1)") == .python, "shebang 识别 Python")
        check(SyntaxLanguage.detectShebang("#!/bin/bash\necho hi") == .shell, "shebang 识别 Shell")

        let py = """
        # 这是注释
        def greet(name):
            msg = "你好"
            return msg + str(42)
        """
        let pyTokens = SyntaxHighlighter.shared.tokens(in: py, language: .python, range: nil)
        check(kind(of: "# 这是注释", in: py, tokens: pyTokens) == .comment, "Python 行注释")
        check(kind(of: "def", in: py, tokens: pyTokens) == .keyword, "Python 关键字")
        check(kind(of: "greet", in: py, tokens: pyTokens) == .function, "Python 函数名")
        check(kind(of: "\"你好\"", in: py, tokens: pyTokens) == .string, "Python 字符串")
        check(kind(of: "42", in: py, tokens: pyTokens) == .number, "Python 数字")

        let php = """
        <?php
        // 行注释
        function total($items) {
            $sum = 0;
            echo "total: $sum";
            return $sum;
        }
        """
        let phpTokens = SyntaxHighlighter.shared.tokens(in: php, language: .php, range: nil)
        check(kind(of: "function", in: php, tokens: phpTokens) == .keyword, "PHP 关键字")
        check(kind(of: "$items", in: php, tokens: phpTokens) == .variable, "PHP 变量")
        check(kind(of: "\"total: $sum\"", in: php, tokens: phpTokens) == .string, "PHP 字符串")
        check(kind(of: "// 行注释", in: php, tokens: phpTokens) == .comment, "PHP 行注释")

        let sh = """
        #!/bin/bash
        NAME="world"
        echo $NAME  # 输出
        echo "hello $NAME"
        """
        let shTokens = SyntaxHighlighter.shared.tokens(in: sh, language: .shell, range: nil)
        check(kind(of: "echo", in: sh, tokens: shTokens) == .keyword, "Shell 内建命令")
        check(kind(of: "$NAME", in: sh, tokens: shTokens) == .variable, "Shell 变量")
        check(kind(of: "# 输出", in: sh, tokens: shTokens) == .comment, "Shell 注释")

        let c = """
        /* 开始
           中间
           结束 */
        int main(void) { return 0; }
        """
        let cTokens = SyntaxHighlighter.shared.tokens(in: c, language: .cFamily, range: nil)
        check(kind(of: "中间", in: c, tokens: cTokens) == .comment, "C 块注释跨行")
        check(kind(of: "int", in: c, tokens: cTokens) == .keyword, "C 关键字")
        check(kind(of: "main", in: c, tokens: cTokens) == .function, "C 函数名")

        let json = "{\"name\": \"value\", \"n\": 3, \"ok\": true}"
        let jsonTokens = SyntaxHighlighter.shared.tokens(in: json, language: .json, range: nil)
        check(kind(of: "\"name\"", in: json, tokens: jsonTokens) == .attribute, "JSON 键名着色")
        check(kind(of: "true", in: json, tokens: jsonTokens) == .keyword, "JSON 字面量")

        // 应用到 NSTextStorage
        let storage = NSTextStorage(string: py)
        SyntaxHighlighter.shared.apply(to: storage, text: py, language: .python,
                                       font: Theme.codeFont(size: 14), range: nil)
        let defLoc = (py as NSString).range(of: "def").location
        let color = storage.attribute(.foregroundColor, at: defLoc, effectiveRange: nil) as? NSColor
        check(color != nil, "NSTextStorage 已写入语法配色")

        // 性能：约 1MB Python 源码
        var big = ""
        for i in 0..<20000 {
            big += "def func_\(i)(x):\n    return \"value \(i)\" + str(x)  # 注释\n"
        }
        let t0 = Date()
        let bigTokens = SyntaxHighlighter.shared.tokens(in: big, language: .python, range: nil)
        let elapsed = Date().timeIntervalSince(t0)
        check(!bigTokens.isEmpty, "大文本分词产出 token", "\(bigTokens.count) 个")
        check(elapsed < 1.5, "1MB 源码分词耗时 < 1.5 秒", String(format: "%.3f 秒", elapsed))
    }
}
