import AppKit

/// 常规文本编辑器后端（基于 NSTextView），适用于中小文件，支持完整编辑能力。
final class PlainTextEditorView: NSView, NSTextViewDelegate {

    private let scrollView = NSScrollView()
    private let gutter = LineNumberGutter()
    let textView: NSTextView

    var onTextChanged: (() -> Void)?
    var onSelectionChanged: ((_ line: Int, _ column: Int) -> Void)?

    private(set) var lineStarts: [Int] = [0]
    private var rebuildWork: DispatchWorkItem?
    private var highlightWork: DispatchWorkItem?
    private var gutterWidth: CGFloat = 52

    /// 当前语法（.none 表示不高亮）
    private(set) var language: SyntaxLanguage = .none

    /// 行号栏字体：跟随正文字号
    var numberFont: NSFont {
        let size = max(9, (textView.font?.pointSize ?? Theme.defaultFontSize) - 2)
        return Theme.codeFont(size: size)
    }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        let font = Theme.codeFont(size: Theme.defaultFontSize)
        textView.font = font
        textView.defaultParagraphStyle = Theme.codeParagraphStyle()
        textView.typingAttributes = SyntaxHighlighter.shared.baseAttributes(font: font)
        textView.textColor = Theme.editorText
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = Theme.caret
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.delegate = self
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)

        // 注意：必须先添加 gutter、后添加 scrollView。
        // macOS 26 上，layer-backed 容器中若先添加 NSScrollView 再添加兄弟视图，
        // NSTextView 的文字层将不会被合成，表现为正文空白（行号可见）。
        gutter.editor = self
        addSubview(gutter)

        scrollView.documentView = textView
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeNotification(_:)),
                                               name: NSText.didChangeNotification,
                                               object: textView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let gw = gutterWidth
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: bounds.height)
        scrollView.frame = NSRect(x: gw, y: 0, width: max(0, bounds.width - gw), height: bounds.height)
        gutter.needsDisplay = true
    }

    // MARK: - 对外接口

    func setText(_ text: String) {
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(NSPoint(x: 0, y: 0))
        rebuildLineStarts()
        updateGutterWidth()
        highlightNow(full: true)
        needsLayout = true
    }

    var text: String { textView.string }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func setFontSize(_ size: CGFloat) {
        let font = Theme.codeFont(size: size)
        textView.font = font
        textView.defaultParagraphStyle = Theme.codeParagraphStyle()
        textView.typingAttributes = SyntaxHighlighter.shared.baseAttributes(font: font)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        updateGutterWidth()
        highlightNow(full: true)
        needsDisplay = true
        gutter.needsDisplay = true
    }

    // MARK: - 语法高亮

    func setLanguage(_ lang: SyntaxLanguage) {
        guard lang != language else { return }
        language = lang
        highlightNow(full: true)
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightNow(full: true) }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func highlightNow(full: Bool) {
        guard let storage = textView.textStorage else { return }
        let font = textView.font ?? Theme.codeFont(size: Theme.defaultFontSize)
        guard language != .none else {
            SyntaxHighlighter.shared.reset(to: storage, font: font, range: nil)
            return
        }
        let length = storage.length
        guard length > 0 else { return }

        var range: NSRange? = nil
        if !(full && length <= SyntaxHighlighter.fullHighlightLimit) {
            // 超大文本只处理可视区域
            range = visibleCharacterRange()
        }
        SyntaxHighlighter.shared.apply(to: storage, text: textView.string,
                                       language: language, font: font, range: range)
        if range != nil { textView.needsDisplay = true }
        gutter.needsDisplay = true
    }

    private func visibleCharacterRange() -> NSRange? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let visible = textView.visibleRect
        guard visible.height > 0 else { return nil }
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        let pad = 4000
        let start = max(0, charRange.location - pad)
        let end = min(length, charRange.location + charRange.length + pad)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func scrollToLine(_ line: Int) {
        guard line >= 1, line - 1 < lineStarts.count else { return }
        let location = lineStarts[line - 1]
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
    }

    func currentLineAndColumn() -> (Int, Int) {
        let loc = textView.selectedRange().location
        let ns = textView.string as NSString
        var line = 1
        var lineStart = 0
        var idx = 0
        while idx < loc && idx < ns.length {
            let r = ns.lineRange(for: NSRange(location: idx, length: 0))
            let next = r.location + r.length
            if next <= idx { break }
            if next <= loc { line += 1; lineStart = next }
            idx = next
        }
        return (line, loc - lineStart + 1)
    }

    func selectedText() -> String {
        let r = textView.selectedRange()
        guard r.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: r)
    }

    // MARK: - 行号

    @objc private func textDidChangeNotification(_ note: Notification) {
        scheduleRebuild()
        updateGutterWidth()
        onTextChanged?()
        gutter.needsDisplay = true
        if language != .none { scheduleHighlight() }
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildLineStarts()
            self?.gutter.needsDisplay = true
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func rebuildLineStarts() {
        let ns = textView.string as NSString
        var starts: [Int] = [0]
        starts.reserveCapacity(max(1, ns.length / 40))
        var idx = 0
        var guardCount = 0
        while idx < ns.length && guardCount < 20_000_000 {
            let r = ns.lineRange(for: NSRange(location: idx, length: 0))
            let next = r.location + r.length
            if next <= idx { break }
            idx = next
            starts.append(idx)
            guardCount += 1
        }
        lineStarts = starts
    }

    private func updateGutterWidth() {
        let digits = max(3, String(max(1, lineStarts.count)).count)
        let charW = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let newWidth = ceil(CGFloat(digits) * charW) + 18
        if abs(newWidth - gutterWidth) > 0.5 {
            gutterWidth = newWidth
            needsLayout = true
        }
    }

    func lineNumber(forCharacterIndex index: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    @objc private func clipBoundsChanged() {
        gutter.needsDisplay = true
        // 超大文本滚动时按可视区域补高亮
        if language != .none,
           let storage = textView.textStorage,
           storage.length > SyntaxHighlighter.fullHighlightLimit {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightNow(full: false) }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        let (line, col) = currentLineAndColumn()
        onSelectionChanged?(line, col)
        gutter.needsDisplay = true
    }

    var currentDocumentRect: NSRect { scrollView.contentView.bounds }
    var documentView: NSTextView { textView }
}

// MARK: - 行号栏

final class LineNumberGutter: NSView {

    weak var editor: PlainTextEditorView?

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

        guard let editor = editor else { return }
        let tv = editor.documentView

        // 当前行高亮
        let (curLine, _) = editor.currentLineAndColumn()
        let scrollView = tv.enclosingScrollView
        let offsetY = scrollView?.contentView.bounds.origin.y ?? 0

        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visibleRect = editor.currentDocumentRect
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let font = editor.numberFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.gutterText
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.gutterTextActive
        ]

        lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, gRange, _ in
            let charIdx = lm.characterIndexForGlyph(at: gRange.location)
            let lineNo = editor.lineNumber(forCharacterIndex: charIdx)
            let y = rect.minY + tv.textContainerInset.height - offsetY
            if y + rect.height < -20 || y > self.bounds.height + 20 { return }

            let str = "\(lineNo)" as NSString
            let a = (lineNo == curLine) ? activeAttrs : attrs
            let size = str.size(withAttributes: a)
            let x = self.bounds.width - size.width - 8
            str.draw(at: NSPoint(x: x, y: y + (rect.height - size.height) / 2), withAttributes: a)
        }
        _ = charRange
    }
}
