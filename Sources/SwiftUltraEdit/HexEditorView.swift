import AppKit

/// 十六进制画布：每行 16 字节，左侧地址由 gutter 绘制。
final class HexCanvasView: NSView {

    let source: HexFileSource
    let bytesPerRow = 16
    var rowHeight: CGFloat = ceil(Theme.defaultFontSize * 1.7)
    var fontSize: CGFloat = Theme.defaultFontSize

    private(set) var caretOffset: Int64 = 0
    private var highNibble = true
    private(set) var selectionStart: Int64?
    private(set) var selectionEnd: Int64?

    var onCaretChanged: ((_ offset: Int64, _ count: Int) -> Void)?
    var onModified: (() -> Void)?
    var onCopyRequest: ((_ text: String) -> Void)?

    private var font: NSFont { Theme.codeFont(size: fontSize) }
    private var charWidth: CGFloat {
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private let insetX: CGFloat = 8

    init(source: HexFileSource) {
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 200))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var totalRows: Int { source.totalRows }

    // MARK: - 布局计算

    var hexColumnWidth: CGFloat { ceil(charWidth * 3) }
    var asciiStartX: CGFloat { insetX + CGFloat(bytesPerRow) * hexColumnWidth + charWidth * 2 }
    var contentWidth: CGFloat { asciiStartX + CGFloat(bytesPerRow) * charWidth + insetX }

    func hexX(for column: Int) -> CGFloat {
        return insetX + CGFloat(column) * hexColumnWidth
    }

    func asciiX(for column: Int) -> CGFloat {
        return asciiStartX + CGFloat(column) * charWidth
    }

    func updateFrame(clipSize: NSSize) {
        let h = max(1, CGFloat(totalRows)) * rowHeight
        let w = max(clipSize.width, contentWidth)
        setFrameSize(NSSize(width: w, height: h))
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()

        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(totalRows - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard first <= last else { return }

        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.editorText
        ]
        let zeroAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.hexZero
        ]
        let asciiAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.hexASCII
        ]
        let selRange = normalizedSelection

        for row in first...last {
            let rowY = CGFloat(row) * rowHeight
            let rowStart = Int64(row) * Int64(bytesPerRow)

            if rowStart <= caretOffset && caretOffset < rowStart + Int64(bytesPerRow) {
                Theme.currentLineFill.setFill()
                NSRect(x: 0, y: rowY, width: bounds.width, height: rowHeight).fill()
            }

            let bytes = source.bytes(at: rowStart, count: bytesPerRow)

            for (i, b) in bytes.enumerated() {
                let offset = rowStart + Int64(i)
                let cellRect = NSRect(x: hexX(for: i) - 1, y: rowY,
                                      width: hexColumnWidth, height: rowHeight)

                if let sel = selRange, sel.contains(offset) {
                    Theme.selectionFill.setFill()
                    cellRect.fill()
                }

                let hexStr = String(format: "%02X", b)
                (hexStr as NSString).draw(at: NSPoint(x: hexX(for: i), y: rowY + (rowHeight - font.pointSize * 1.3) / 2),
                                          withAttributes: b == 0 ? zeroAttrs : hexAttrs)

                let scalar = b >= 0x20 && b < 0x7F ? String(UnicodeScalar(b)) : "."
                (scalar as NSString).draw(at: NSPoint(x: asciiX(for: i), y: rowY + (rowHeight - font.pointSize * 1.3) / 2),
                                          withAttributes: asciiAttrs)
            }
        }

        drawCaret()
    }

    private func drawCaret() {
        guard window?.firstResponder === self else { return }
        let row = Int(caretOffset / Int64(bytesPerRow))
        let col = Int(caretOffset % Int64(bytesPerRow))
        let x = hexX(for: col) + (highNibble ? 0 : charWidth)
        let y = CGFloat(row) * rowHeight + rowHeight - 3
        Theme.caret.setFill()
        NSRect(x: x, y: y, width: charWidth, height: 2).fill()
    }

    var normalizedSelection: Range<Int64>? {
        guard let s = selectionStart, let e = selectionEnd else { return nil }
        if s == e { return nil }
        return min(s, e)..<(max(s, e) + 1)
    }

    var selectionByteCount: Int {
        return normalizedSelection.map { $0.count } ?? 0
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let offset = offset(at: p)

        if event.modifierFlags.contains(.shift) {
            selectionEnd = offset
        } else {
            selectionStart = offset
            selectionEnd = offset
        }
        caretOffset = offset
        highNibble = true
        notifyCaret()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let offset = offset(at: p)
        if selectionStart == nil { selectionStart = caretOffset }
        selectionEnd = offset
        caretOffset = offset
        notifyCaret()
        needsDisplay = true
        autoscroll(with: event)
    }

    private func offset(at point: NSPoint) -> Int64 {
        let row = max(0, min(totalRows - 1, Int(floor(point.y / rowHeight))))
        var col: Int
        if point.x >= asciiStartX {
            col = Int(floor((point.x - asciiStartX) / charWidth))
        } else {
            col = Int(floor((point.x - insetX) / hexColumnWidth))
        }
        col = max(0, min(bytesPerRow - 1, col))
        let offset = Int64(row) * Int64(bytesPerRow) + Int64(col)
        return min(offset, max(0, source.size - 1))
    }

    private func notifyCaret() {
        onCaretChanged?(caretOffset, selectionByteCount)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 126: move(by: Int64(-bytesPerRow)); return
        case 125: move(by: Int64(bytesPerRow)); return
        case 123: move(by: -1); return
        case 124: move(by: 1); return
        case 115: moveTo(rowStart: caretOffset); return
        case 119: moveTo(rowEnd: caretOffset); return
        case 116: move(by: Int64(-bytesPerRow * 20)); return
        case 121: move(by: Int64(bytesPerRow * 20)); return
        default: break
        }

        if flags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "c" { copySelection(); return }
            if key == "a" {
                selectionStart = 0
                selectionEnd = max(0, source.size - 1)
                needsDisplay = true
                return
            }
            super.keyDown(with: event)
            return
        }

        // 十六进制输入（覆盖模式）
        if let chars = event.characters, let first = chars.uppercased().first,
           let nibble = first.hexDigitValue {
            guard caretOffset < source.size else { return }
            var b = source.byte(at: caretOffset)
            if highNibble {
                b = (b & 0x0F) | (UInt8(nibble) << 4)
            } else {
                b = (b & 0xF0) | UInt8(nibble)
            }
            source.setByte(b, at: caretOffset)
            if highNibble {
                highNibble = false
            } else {
                highNibble = true
                if caretOffset < source.size - 1 { caretOffset += 1 }
            }
            onModified?()
            notifyCaret()
            needsDisplay = true
            scrollCaretToVisible()
            return
        }

        super.keyDown(with: event)
    }

    private func move(by delta: Int64) {
        moveToAbsolute(caretOffset + delta)
    }

    private func moveTo(rowStart offset: Int64) {
        let row = offset / Int64(bytesPerRow)
        moveToAbsolute(row * Int64(bytesPerRow))
    }

    private func moveTo(rowEnd offset: Int64) {
        let row = offset / Int64(bytesPerRow)
        moveToAbsolute(min(source.size - 1, row * Int64(bytesPerRow) + Int64(bytesPerRow) - 1))
    }

    func moveToAbsolute(_ offset: Int64) {
        caretOffset = min(max(0, offset), max(0, source.size - 1))
        selectionStart = caretOffset
        selectionEnd = caretOffset
        highNibble = true
        notifyCaret()
        needsDisplay = true
        scrollCaretToVisible()
    }

    func scrollCaretToVisible() {
        guard let sv = enclosingScrollView else { return }
        let row = CGFloat(caretOffset / Int64(bytesPerRow))
        let y = row * rowHeight
        let visible = sv.contentView.bounds
        if y < visible.minY || y + rowHeight > visible.maxY {
            scroll(NSPoint(x: visible.minX, y: max(0, y - visible.height / 2)))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    func scrollToOffset(_ offset: Int64) {
        guard let sv = enclosingScrollView else { return }
        let row = CGFloat(offset / Int64(bytesPerRow))
        let y = max(0, row * rowHeight - sv.contentView.bounds.height / 3)
        scroll(NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        moveToAbsolute(offset)
    }

    private func copySelection() {
        guard let sel = normalizedSelection else {
            let b = source.byte(at: caretOffset)
            onCopyRequest?(String(format: "%02X", b))
            return
        }
        var parts: [String] = []
        var cursor = sel.lowerBound
        while cursor < sel.upperBound {
            parts.append(String(format: "%02X", source.byte(at: cursor)))
            cursor += 1
        }
        onCopyRequest?(parts.joined(separator: " "))
    }

    func refresh() {
        needsDisplay = true
    }
}

// MARK: - 地址栏

final class HexAddressGutterView: NSView {

    weak var canvas: HexCanvasView?
    weak var scrollView: NSScrollView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        dirtyRect.fill()

        Theme.gutterDivider.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
        path.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        path.lineWidth = 1
        path.stroke()

        guard let canvas = canvas else { return }
        let rh = canvas.rowHeight
        let offsetY = scrollView?.contentView.bounds.origin.y ?? 0
        let first = max(0, Int(floor(offsetY / rh)))
        let last = min(canvas.totalRows - 1, first + Int(ceil(bounds.height / rh)) + 2)
        guard first <= last else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.codeFont(size: max(9, canvas.fontSize - 2)),
            .foregroundColor: Theme.gutterText
        ]
        for row in first...last {
            let y = CGFloat(row) * rh - offsetY
            if y + rh < 0 || y > bounds.height { continue }
            let addr = String(format: "%08llX", Int64(row) * 16)
            let size = (addr as NSString).size(withAttributes: attrs)
            (addr as NSString).draw(at: NSPoint(x: bounds.width - size.width - 8,
                                                y: y + (rh - size.height) / 2),
                                    withAttributes: attrs)
        }
    }
}

// MARK: - 容器

final class HexEditorView: NSView {

    let source: HexFileSource
    private let scrollView = NSScrollView()
    private let canvas: HexCanvasView
    private let gutter = HexAddressGutterView()
    private let gutterWidth: CGFloat = 96
    private var fontSize: CGFloat = Theme.defaultFontSize

    var onCaretChanged: ((_ offset: Int64, _ count: Int) -> Void)?
    var onModified: (() -> Void)?

    init(source: HexFileSource) {
        self.source = source
        self.canvas = HexCanvasView(source: source)
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

        setFontSize(fontSize)

        canvas.onCaretChanged = { [weak self] offset, count in
            self?.gutter.needsDisplay = true
            self?.onCaretChanged?(offset, count)
        }
        canvas.onModified = { [weak self] in
            self?.onModified?()
        }
        canvas.onCopyRequest = { text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        // 注意：必须先添加 gutter、后添加 scrollView（与 PlainTextEditorView 相同）。
        // macOS 26 上 layer-backed 容器中若先添加 NSScrollView 再添加兄弟视图，
        // scrollView 内容（画布文字）将不会被合成，表现为只有地址列、正文空白。
        gutter.canvas = canvas
        gutter.scrollView = scrollView
        addSubview(gutter)

        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
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

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        canvas.fontSize = size
        canvas.rowHeight = ceil(size * 1.7)
        needsLayout = true
        canvas.refresh()
        gutter.needsDisplay = true
    }

    func focus() {
        window?.makeFirstResponder(canvas)
    }

    func scrollToOffset(_ offset: Int64) {
        canvas.scrollToOffset(offset)
    }

    func refresh() {
        canvas.updateFrame(clipSize: scrollView.contentSize)
        canvas.refresh()
        gutter.needsDisplay = true
    }
}
