import AppKit

protocol TextCanvasDelegate: AnyObject {
    func canvasDidChangeCaret(line: Int, column: Int, byteOffset: Int64)
    func canvasDidRequestLineEdit(line: Int, initialText: String, column: Int)
    func canvasDidModifyDocument()
    func canvasDidCopy(_ text: String)
}

/// 虚拟化文本画布：只绘制视口内的行，行内容按需从磁盘读取。
/// 支持行级选择、行级编辑、删除行、追加行。
final class TextCanvasView: NSView {

    weak var delegate: TextCanvasDelegate?
    let document: TextDocument

    var lineHeight: CGFloat = ceil(Theme.defaultFontSize * 1.62) {
        didSet { if lineHeight != oldValue { clearSyntaxCache() } }
    }
    var fontSize: CGFloat = Theme.defaultFontSize {
        didSet { if fontSize != oldValue { clearSyntaxCache() } }
    }

    /// 当前语法（.none 表示不高亮）
    var language: SyntaxLanguage = .none {
        didSet {
            if language != oldValue {
                clearSyntaxCache()
                needsDisplay = true
            }
        }
    }

    private var syntaxCache: [Int: NSAttributedString] = [:]
    private var stateCache: [Int: ScanState] = [:]

    private var tokenizer: SyntaxTokenizer? {
        return language == .none ? nil : SyntaxHighlighter.shared.tokenizer(for: language)
    }

    func clearSyntaxCache() {
        syntaxCache.removeAll(keepingCapacity: true)
        stateCache.removeAll(keepingCapacity: true)
    }

    private(set) var caretLine = 0
    private(set) var caretColumn = 0
    private(set) var selectionAnchor: Int? = nil
    private(set) var selectionHead: Int? = nil
    private let textInsetX: CGFloat = 8

    private var font: NSFont { Theme.codeFont(size: fontSize) }

    init(document: TextDocument) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 3000, height: 100))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var totalLines: Int { document.displayLineCount }

    // MARK: - 尺寸

    func updateFrame(clipSize: NSSize) {
        let h = max(1, CGFloat(totalLines)) * lineHeight
        let w = max(clipSize.width, max(1200, measuredMaxWidth + textInsetX * 2))
        setFrameSize(NSSize(width: w, height: h))
        needsDisplay = true
    }

    private var measuredMaxWidth: CGFloat = 1200

    func resetWidthMeasurement() {
        measuredMaxWidth = 1200
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()

        guard document.index.built else {
            drawPlaceholder("正在建立行索引…")
            return
        }

        let first = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let last = min(totalLines - 1, Int(ceil(dirtyRect.maxY / lineHeight)))
        guard first <= last else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.editorText
        ]
        let deletedAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.gutterText,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ]

        let sel = selectionRange
        var widthProbe: CGFloat = measuredMaxWidth

        for line in first...last {
            let rowRect = NSRect(x: 0, y: CGFloat(line) * lineHeight, width: bounds.width, height: lineHeight)

            if document.isLineDeleted(line) {
                Theme.deletedLineFill.setFill()
                rowRect.fill()
            } else if line == caretLine && sel == nil {
                Theme.currentLineFill.setFill()
                rowRect.fill()
            }

            if let s = sel, line >= s.lowerBound, line < s.upperBound {
                Theme.selectionFill.setFill()
                rowRect.fill()
            }

            let raw = document.lineText(line)
            let display = sanitizeForDisplay(raw)
            let ns = display as NSString
            let drawRect = NSRect(x: textInsetX,
                                  y: rowRect.minY + (lineHeight - font.pointSize * 1.35) / 2,
                                  width: max(10, bounds.width - textInsetX * 2),
                                  height: lineHeight)

            if !document.isLineDeleted(line), let tk = tokenizer {
                let attributed = attributedLine(line: line, text: ns, tokenizer: tk)
                attributed.draw(in: drawRect)
                if line % 7 == 0 {
                    let w = attributed.size().width + textInsetX * 2
                    if w > widthProbe { widthProbe = w }
                }
            } else {
                let useAttrs = document.isLineDeleted(line) ? deletedAttrs : attrs
                ns.draw(in: drawRect, withAttributes: useAttrs)
                if line % 7 == 0 {
                    let w = ns.size(withAttributes: useAttrs).width + textInsetX * 2
                    if w > widthProbe { widthProbe = w }
                }
            }
        }

        // 超长行时渐进扩展画布宽度
        if widthProbe > measuredMaxWidth + 40 {
            measuredMaxWidth = min(widthProbe, 30000)
            if let clip = enclosingScrollView?.contentView {
                updateFrame(clipSize: clip.bounds.size)
            }
        }

        drawCaret()
    }

    /// 单行着色（带缓存；跨行注释状态按绘制顺序传递）
    private func attributedLine(line: Int, text: NSString, tokenizer: SyntaxTokenizer) -> NSAttributedString {
        if let cached = syntaxCache[line] { return cached }

        var state = stateCache[line] ?? .normal
        let tokens = tokenizer.tokenizeLine(text, start: 0, end: text.length, state: &state)
        stateCache[line + 1] = state

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.editorText
        ]
        let attributed = NSMutableAttributedString(string: text as String, attributes: base)
        for t in tokens {
            guard t.range.location >= 0,
                  t.range.location + t.range.length <= attributed.length else { continue }
            attributed.addAttribute(.foregroundColor,
                                    value: SyntaxHighlighter.shared.color(for: t.kind),
                                    range: t.range)
        }

        if syntaxCache.count > 30_000 {
            syntaxCache.removeAll(keepingCapacity: true)
            stateCache.removeAll(keepingCapacity: true)
        }
        syntaxCache[line] = attributed
        return attributed
    }

    private func drawPlaceholder(_ text: String) {        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont(size: 13),
            .foregroundColor: Theme.gutterText
        ]
        (text as NSString).draw(at: NSPoint(x: 16, y: 16), withAttributes: attrs)
    }

    private func drawCaret() {
        guard window?.firstResponder === self else { return }
        if selectionRange != nil { return }
        let r = caretRect(line: caretLine, column: caretColumn)
        Theme.caret.setFill()
        r.fill()
    }

    func caretRect(line: Int, column: Int) -> NSRect {
        let text = sanitizeForDisplay(document.lineText(line))
        let chars = Array(text)
        let col = min(max(0, column), chars.count)
        let prefix = String(chars.prefix(col))
        let w = (prefix as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: textInsetX + w, y: CGFloat(line) * lineHeight + 1,
                      width: 1.6, height: lineHeight - 2)
    }

    // MARK: - 选���

    var selectionRange: Range<Int>? {
        guard let a = selectionAnchor, let h = selectionHead, a != h else { return nil }
        return min(a, h)..<max(a, h)
    }

    var selectedLineCount: Int {
        return selectionRange.map { $0.upperBound - $0.lowerBound } ?? 0
    }

    func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let line = lineIndex(at: p)
        let col = columnIndex(at: p, line: line)

        if event.modifierFlags.contains(.shift) {
            selectionHead = line
        } else if event.clickCount >= 2 {
            selectionAnchor = nil
            selectionHead = nil
            caretLine = line
            caretColumn = col
            delegate?.canvasDidRequestLineEdit(line: line,
                                               initialText: document.lineText(line),
                                               column: col)
        } else {
            selectionAnchor = line
            selectionHead = line
            caretLine = line
            caretColumn = col
        }
        notifyCaret()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let line = lineIndex(at: p)
        if selectionAnchor == nil { selectionAnchor = caretLine }
        selectionHead = line
        caretLine = line
        notifyCaret()
        needsDisplay = true
        autoscroll(with: event)
    }

    private func lineIndex(at point: NSPoint) -> Int {
        let raw = Int(floor(point.y / lineHeight))
        return min(max(0, raw), max(0, totalLines - 1))
    }

    private func columnIndex(at point: NSPoint, line: Int) -> Int {
        let text = sanitizeForDisplay(document.lineText(line))
        let chars = Array(text)
        let x = point.x - textInsetX
        if x <= 0 { return 0 }
        var width: CGFloat = 0
        for (i, ch) in chars.enumerated() {
            let w = (String(ch) as NSString).size(withAttributes: [.font: font]).width
            if width + w / 2 > x { return i }
            width += w
        }
        return chars.count
    }

    private func notifyCaret() {
        let offset = document.index.offset(ofLine: caretLine) ?? 0
        delegate?.canvasDidChangeCaret(line: caretLine + 1, column: caretColumn + 1, byteOffset: offset)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        guard document.index.built else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let visibleLines = max(1, Int((enclosingScrollView?.contentView.bounds.height ?? 600) / lineHeight) - 1)

        switch event.keyCode {
        case 126: // up
            if flags.contains(.command) { moveCaret(toLine: 0, column: 0) }
            else { moveCaret(toLine: max(0, caretLine - 1), column: caretColumn) }
            return
        case 125: // down
            if flags.contains(.command) { moveCaret(toLine: totalLines - 1, column: 0) }
            else { moveCaret(toLine: min(totalLines - 1, caretLine + 1), column: caretColumn) }
            return
        case 123: // left
            if caretColumn > 0 { moveCaret(toLine: caretLine, column: caretColumn - 1) }
            else if caretLine > 0 {
                let prev = max(0, caretLine - 1)
                moveCaret(toLine: prev, column: charCount(prev))
            }
            return
        case 124: // right
            if caretColumn < charCount(caretLine) { moveCaret(toLine: caretLine, column: caretColumn + 1) }
            else if caretLine < totalLines - 1 { moveCaret(toLine: caretLine + 1, column: 0) }
            return
        case 116: // page up
            moveCaret(toLine: max(0, caretLine - visibleLines), column: caretColumn)
            return
        case 121: // page down
            moveCaret(toLine: min(totalLines - 1, caretLine + visibleLines), column: caretColumn)
            return
        case 115: // home
            if flags.contains(.command) { moveCaret(toLine: 0, column: 0) }
            else { moveCaret(toLine: caretLine, column: 0) }
            return
        case 119: // end
            if flags.contains(.command) { moveCaret(toLine: totalLines - 1, column: 0) }
            else { moveCaret(toLine: caretLine, column: charCount(caretLine)) }
            return
        case 36: // return
            beginEditAtCaret(prefix: nil)
            return
        case 51, 117: // delete / forward delete
            deleteSelectionOrCaretLine()
            return
        default:
            break
        }

        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "c" {
                copySelection()
                return
            }
            if event.charactersIgnoringModifiers?.lowercased() == "a" {
                selectionAnchor = 0
                selectionHead = totalLines
                needsDisplay = true
                return
            }
            if event.charactersIgnoringModifiers?.lowercased() == "e" {
                beginEditAtCaret(prefix: nil)
                return
            }
            super.keyDown(with: event)
            return
        }

        if let chars = event.characters, !chars.isEmpty,
           !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            beginEditAtCaret(prefix: chars)
            return
        }

        super.keyDown(with: event)
    }

    private func beginEditAtCaret(prefix: String?) {
        delegate?.canvasDidRequestLineEdit(line: caretLine,
                                           initialText: document.lineText(caretLine),
                                           column: prefix == nil ? caretColumn : -1)
        if let p = prefix, !p.isEmpty {
            pendingInitialInput = p
        }
    }

    /// 若用户直接键入字符，则在编辑框中把它插入到光标处
    private(set) var pendingInitialInput: String?

    func consumePendingInput() -> String? {
        defer { pendingInitialInput = nil }
        return pendingInitialInput
    }

    private func deleteSelectionOrCaretLine() {
        if let sel = selectionRange {
            for line in sel { document.deleteLine(line) }
            clearSelection()
        } else {
            if caretLine < document.index.totalLines {
                document.deleteLine(caretLine)
            } else {
                let idx = caretLine - document.index.totalLines
                if idx >= 0 && idx < document.appendedLines.count {
                    document.deleteLine(caretLine)
                }
            }
        }
        delegate?.canvasDidModifyDocument()
        needsDisplay = true
        notifyCaret()
    }

    func copySelection() {
        if let sel = selectionRange {
            var parts: [String] = []
            for line in sel { parts.append(document.lineText(line)) }
            delegate?.canvasDidCopy(parts.joined(separator: "\n"))
        } else {
            delegate?.canvasDidCopy(document.lineText(caretLine))
        }
    }

    private func charCount(_ line: Int) -> Int {
        return document.lineText(line).count
    }

    func moveCaret(toLine line: Int, column: Int) {
        caretLine = min(max(0, line), max(0, totalLines - 1))
        clearSelection()
        let maxCol = charCount(caretLine)
        caretColumn = min(max(0, column), maxCol)
        notifyCaret()
        needsDisplay = true
        scrollCaretToVisible()
    }

    func scrollCaretToVisible() {
        guard let sv = enclosingScrollView else { return }
        let y = CGFloat(caretLine) * lineHeight
        let visible = sv.contentView.bounds
        if y < visible.minY {
            scroll(NSPoint(x: visible.minX, y: max(0, y - lineHeight * 2)))
        } else if y + lineHeight > visible.maxY {
            scroll(NSPoint(x: visible.minX, y: y - visible.height + lineHeight * 2))
        }
        enclosingScrollView?.reflectScrolledClipView(sv.contentView)
    }

    func scrollToLine(_ line: Int) {
        guard let sv = enclosingScrollView else { return }
        let y = max(0, CGFloat(line) * lineHeight - sv.contentView.bounds.height / 3)
        scroll(NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        moveCaret(toLine: line, column: 0)
    }

    func refreshAfterEdit(line: Int, text: String) {
        document.setLine(line, text: text)
        clearSyntaxCache()
        caretLine = line
        caretColumn = min(caretColumn, text.count)
        delegate?.canvasDidModifyDocument()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        notifyCaret()
    }

    func refreshAll() {
        needsDisplay = true
    }
}
