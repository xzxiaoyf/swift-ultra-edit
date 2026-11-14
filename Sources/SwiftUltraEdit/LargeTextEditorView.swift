import AppKit

/// 大文件文本编辑器：NSScrollView + 虚拟画布 + 固定行号栏 + 行内编辑框。
final class LargeTextEditorView: NSView, TextCanvasDelegate, NSTextFieldDelegate {

    let document: TextDocument
    private let scrollView = NSScrollView()
    private let canvas: TextCanvasView
    private let gutter = LargeLineGutterView()

    private var inlineEditor: NSTextField?
    private var editingLine: Int = -1
    private var gutterWidth: CGFloat = 64
    private var fontSize: CGFloat = Theme.defaultFontSize

    var onModified: (() -> Void)?
    var onCaretChanged: ((_ line: Int, _ column: Int, _ byteOffset: Int64) -> Void)?
    var onIndexReady: (() -> Void)?

    init(document: TextDocument) {
        self.document = document
        self.canvas = TextCanvasView(document: document)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.documentView = canvas

        canvas.delegate = self
        applyFontSize(fontSize)

        // 注意：必须先添加 gutter、后添加 scrollView（macOS 26 合成顺序问题，见 PlainTextEditorView）。
        gutter.canvas = canvas
        gutter.scrollView = scrollView
        addSubview(gutter)

        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        updateGutterWidth()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0,
                                  width: max(0, bounds.width - gutterWidth), height: bounds.height)
        canvas.updateFrame(clipSize: scrollView.contentSize)
        gutter.needsDisplay = true
    }

    @objc private func clipBoundsChanged() {
        gutter.needsDisplay = true
    }

    // MARK: - 加载

    func load() {
        document.buildIndex { [weak self] in
            guard let self = self else { return }
            self.canvas.updateFrame(clipSize: self.scrollView.contentSize)
            self.canvas.resetWidthMeasurement()
            self.canvas.refreshAll()
            self.gutter.needsDisplay = true
            self.onIndexReady?()
        }
    }

    // MARK: - 外观

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        applyFontSize(size)
        updateGutterWidth()
        needsLayout = true
        canvas.refreshAll()
        gutter.needsDisplay = true
    }

    private func applyFontSize(_ size: CGFloat) {
        let lh = ceil(size * 1.62)
        canvas.fontSize = size
        canvas.lineHeight = lh
    }

    private func updateGutterWidth() {
        let digits = max(4, String(max(1, document.displayLineCount)).count)
        let charW = ("0" as NSString).size(withAttributes: [.font: Theme.codeFont(size: max(9, fontSize - 2))]).width
        gutterWidth = ceil(CGFloat(digits) * charW) + 20
    }

    /// 设置语法高亮语言
    func setLanguage(_ lang: SyntaxLanguage) {
        canvas.language = lang
    }

    // MARK: - 定位

    func focus() {
        window?.makeFirstResponder(canvas)
    }

    func scrollToLine(_ line: Int) {
        canvas.scrollToLine(max(0, line - 1))
        gutter.needsDisplay = true
    }

    func caretInfo() -> (line: Int, column: Int) {
        let offset = document.index.offset(ofLine: canvas.caretLine) ?? 0
        _ = offset
        return (canvas.caretLine + 1, canvas.caretColumn + 1)
    }

    // MARK: - 行内编辑

    func beginEditing(line: Int, column: Int) {
        cancelInlineEditing()
        guard line >= 0, line < document.displayLineCount else { return }

        let rowY = CGFloat(line) * canvas.lineHeight
        let rect = NSRect(x: 0, y: rowY, width: max(canvas.bounds.width, 400), height: canvas.lineHeight)
        let field = NSTextField(frame: rect)
        field.stringValue = document.lineText(line)
        field.font = Theme.codeFont(size: fontSize)
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor
        field.textColor = Theme.editorText
        field.focusRingType = .none
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        canvas.addSubview(field)

        editingLine = line
        inlineEditor = field

        window?.makeFirstResponder(field)
        if let tv = field.currentEditor() {
            let len = (field.stringValue as NSString).length
            let col: Int
            if let pending = canvas.consumePendingInput(), !pending.isEmpty {
                let insertAt = min(column >= 0 ? column : len, len)
                let ns = NSMutableString(string: field.stringValue)
                ns.insert(pending, at: insertAt)
                field.stringValue = ns as String
                col = insertAt + (pending as NSString).length
            } else {
                col = column >= 0 ? min(column, len) : len
            }
            tv.selectedRange = NSRange(location: col, length: 0)
        }
        field.scrollToVisible(field.bounds)
    }

    func commitInlineEdit() {
        guard let field = inlineEditor, editingLine >= 0 else { return }
        let text = field.stringValue
        let line = editingLine
        cancelInlineEditing()
        canvas.refreshAfterEdit(line: line, text: text)
        onModified?()
        updateGutterWidth()
        needsLayout = true
        focus()
    }

    func cancelInlineEditing() {
        inlineEditor?.removeFromSuperview()
        inlineEditor = nil
        editingLine = -1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineEditing()
            focus()
            return true
        }
        return false
    }

    // MARK: - TextCanvasDelegate

    func canvasDidChangeCaret(line: Int, column: Int, byteOffset: Int64) {
        onCaretChanged?(line, column, byteOffset)
        gutter.needsDisplay = true
    }

    func canvasDidRequestLineEdit(line: Int, initialText: String, column: Int) {
        beginEditing(line: line, column: column)
    }

    func canvasDidModifyDocument() {
        onModified?()
        gutter.needsDisplay = true
    }

    func canvasDidCopy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - 行号栏

final class LargeLineGutterView: NSView {

    weak var canvas: TextCanvasView?
    weak var scrollView: NSScrollView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        dirtyRect.fill()

        Theme.gutterDivider.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        divider.lineWidth = 1
        divider.stroke()

        guard let canvas = canvas, canvas.document.index.built else { return }
        let lh = canvas.lineHeight
        let offsetY = scrollView?.contentView.bounds.origin.y ?? 0
        let first = max(0, Int(floor(offsetY / lh)))
        let visibleCount = Int(ceil(bounds.height / lh)) + 2
        let last = min(canvas.totalLines - 1, first + visibleCount)
        guard first <= last else { return }

        let numberFont = Theme.codeFont(size: max(9, canvas.fontSize - 2))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: Theme.gutterText
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: Theme.gutterTextActive
        ]

        for line in first...last {
            let y = CGFloat(line) * lh - offsetY
            if y + lh < 0 || y > bounds.height { continue }

            // 修改标记
            if canvas.document.isLineEdited(line) {
                Theme.modifiedLineMark.setFill()
                NSRect(x: bounds.width - 3, y: y + 2, width: 3, height: lh - 4).fill()
            }

            let str = "\(line + 1)" as NSString
            let a = (line == canvas.caretLine) ? activeAttrs : attrs
            let size = str.size(withAttributes: a)
            str.draw(at: NSPoint(x: bounds.width - size.width - 10,
                                 y: y + (lh - size.height) / 2),
                     withAttributes: a)
        }
    }
}
