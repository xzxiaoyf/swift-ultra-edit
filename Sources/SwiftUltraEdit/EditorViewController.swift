import AppKit

enum EditorMode: Int {
    case text = 0
    case hex = 1
}

final class EditorViewController: NSViewController {

    // MARK: - UI

    private let headerBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "未打开文件")
    private let detailLabel = NSTextField(labelWithString: "")
    private var modeControl: NSSegmentedControl!
    private var encodingPopup: NSPopUpButton!
    private var saveButton: NSButton!
    private var gotoButton: NSButton!
    private let container = NSView()
    private let statusBar = NSView()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")

    // MARK: - 状态

    private(set) var currentURL: URL?
    /// 新建但尚未保存到磁盘的文档（currentURL == nil）
    private(set) var isUntitled = false
    private(set) var mode: EditorMode = .text
    private(set) var dirty = false

    private var plainView: PlainTextEditorView?
    private var largeView: LargeTextEditorView?
    private var hexView: HexEditorView?
    private var textDocument: TextDocument?
    private var hexSource: HexFileSource?

    private var smallFileData: Data?
    private var smallEncoding: TextEncodingKind = .utf8
    private var smallHasBOM = false

    private var currentSize: Int64 = 0
    private var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "SUEFontSize")
        return saved >= 9 ? CGFloat(saved) : Theme.defaultFontSize
    }()
    private let largeThreshold: Int64 = 16 * 1024 * 1024

    /// 超长行阈值：单行超过该字符数时自动启用换行显示。
    /// 依据：不换行排版会把文本视图撑到数百万点宽（367 KB 单行 ≈ 318 万点），
    /// 触发巨型位图图层重绘，界面长时间无响应。
    private let longLineThreshold = 5_000

    /// 用户是否允许对超长行自动换行（默认开启，可菜单切换）
    private(set) var wrapLongLinesPreferred: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "SUEWrapLongLines") == nil { return true }
        return defaults.bool(forKey: "SUEWrapLongLines")
    }()

    /// 当前文档是否正在以换行方式显示
    private(set) var currentDocumentWrapped = false

    // MARK: - 语法高亮状态

    /// 用户手动指定的语言（nil 表示自动检测）
    private var syntaxOverride: SyntaxLanguage?
    private(set) var syntaxEnabled: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "SUESyntaxEnabled") == nil { return true }
        return defaults.bool(forKey: "SUESyntaxEnabled")
    }()
    private(set) var currentLanguage: SyntaxLanguage = .none

    /// 是否处于「自动检测」模式（未被手动指定语言）
    var usesAutoSyntax: Bool { syntaxOverride == nil }

    var onTitleChange: ((String) -> Void)?

    var hasUnsavedChanges: Bool { dirty }

    // MARK: - 视图

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateHeader()
        updateStatus()
    }

    private func setupUI() {
        view.wantsLayer = true

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.boldUIFont(size: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.uiFont(size: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        modeControl = NSSegmentedControl(labels: ["文本", "十六进制"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(modeChanged(_:)))
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for kind in TextEncodingKind.allCases {
            encodingPopup.addItem(withTitle: kind.displayName)
        }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))
        encodingPopup.controlSize = .small
        encodingPopup.font = Theme.uiFont(size: 11)
        encodingPopup.translatesAutoresizingMaskIntoConstraints = false

        gotoButton = NSButton(title: "跳转", target: self, action: #selector(gotoTapped))
        gotoButton.bezelStyle = .rounded
        gotoButton.controlSize = .small
        gotoButton.font = Theme.uiFont(size: 11)
        gotoButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = Theme.uiFont(size: 11)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [modeControl, encodingPopup, gotoButton, saveButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        headerBar.addSubview(titleLabel)
        headerBar.addSubview(detailLabel)
        headerBar.addSubview(controls)
        view.addSubview(headerBar)
        view.addSubview(container)
        view.addSubview(statusBar)

        statusLeft.font = Theme.uiFont(size: 11)
        statusLeft.textColor = .secondaryLabelColor
        statusLeft.lineBreakMode = .byTruncatingTail
        statusLeft.translatesAutoresizingMaskIntoConstraints = false
        statusRight.font = Theme.monoSmall
        statusRight.textColor = .secondaryLabelColor
        statusRight.alignment = .right
        statusRight.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLeft)
        statusBar.addSubview(statusRight)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 54),

            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),

            controls.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -14),
            controls.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 130),
            encodingPopup.widthAnchor.constraint(equalToConstant: 150),

            container.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),

            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 14),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLeft.trailingAnchor.constraint(lessThanOrEqualTo: statusRight.leadingAnchor, constant: -12),

            statusRight.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -14),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        // 分隔线
        let topDivider = NSBox(frame: .zero)
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(topDivider)
        NSLayoutConstraint.activate([
            topDivider.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            topDivider.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1)
        ])

        let bottomDivider = NSBox(frame: .zero)
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(bottomDivider)
        NSLayoutConstraint.activate([
            bottomDivider.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: statusBar.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func install(_ v: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func teardownEditor() {
        container.subviews.forEach { $0.removeFromSuperview() }
        plainView = nil
        largeView = nil
        hexView = nil
        textDocument = nil
        hexSource = nil
        smallFileData = nil
        dirty = false
        currentDocumentWrapped = false
        statusRight.stringValue = ""
    }

    // MARK: - 打开 / 加载

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要打开的文件（文本或二进制）"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    /// 新建空白文本文档（未命名，⌘S 保存时弹出位置选择）
    func newDocument() {
        guard confirmDiscardIfNeeded() else { return }
        currentURL = nil
        mode = .text
        modeControl.selectedSegment = 0
        syntaxOverride = nil
        currentLanguage = .none
        teardownEditor()
        smallFileData = nil
        smallEncoding = .utf8
        smallHasBOM = false
        currentSize = 0

        let v = PlainTextEditorView(frame: .zero)
        v.setFontSize(fontSize)
        v.setText("")
        v.setLanguage(.none)
        v.onTextChanged = { [weak self] in self?.markDirty() }
        v.onSelectionChanged = { [weak self] line, col in
            self?.statusRight.stringValue = "行 \(line) : 列 \(col)"
        }
        plainView = v
        install(v)
        isUntitled = true
        selectEncodingInPopup(.utf8)
        updateHeader()
        updateStatus()
        v.focus()
    }

    func open(url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        Bench.mark("open: 开始 \(url.lastPathComponent)")
        currentURL = url
        isUntitled = false
        mode = .text
        modeControl.selectedSegment = 0
        syntaxOverride = nil
        loadCurrent()
        Bench.mark("open: loadCurrent 返回")
        view.window?.makeFirstResponder(nil)
        Bench.mark("open: 取消第一响应者")
        focusEditor()
        Bench.mark("open: 聚焦编辑器完成")
    }

    private func focusEditor() {
        if let v = plainView { v.focus() }
        else if let v = largeView { v.focus() }
        else if let v = hexView { v.focus() }
    }

    private func loadCurrent() {
        teardownEditor()
        guard let url = currentURL else {
            updateHeader()
            updateStatus()
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            alertError(title: "无法打开目录", message: "请选择一个文件而不是文件夹：\(url.lastPathComponent)")
            currentURL = nil
            updateHeader()
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        currentSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        updateHeader()

        if mode == .hex {
            loadHex(url: url)
        } else {
            loadText(url: url)
        }
        updateStatus()
    }

    private func loadText(url: URL) {
        Bench.mark("loadText 开始 size=\(currentSize)")
        if currentSize > largeThreshold {
            beginLargeMode(url: url)
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            alertError(title: "无法读取文件", message: url.path)
            return
        }
        Bench.mark("已读取 \(data.count) 字节")

        if EncodingDetector.looksBinary(data) {
            switchToHexBecauseBinary(url: url)
            return
        }
        Bench.mark("二进制判定完成")

        let detected = EncodingDetector.detect(data: data)
        Bench.mark("编码探测完成 \(detected.kind.displayName)")
        guard let text = EncodingCodec.decode(data, as: detected.kind) else {
            switchToHexBecauseBinary(url: url)
            return
        }
        Bench.mark("解码完成 字符数=\(text.count)")

        smallFileData = data
        smallEncoding = detected.kind
        smallHasBOM = detected.hasBOM

        currentLanguage = resolveLanguage(for: url)
        currentDocumentWrapped = wrapLongLinesPreferred && textHasLineLongerThan(text, limit: longLineThreshold)
        let v = PlainTextEditorView(frame: .zero)
        v.setFontSize(fontSize)
        let estimatedWidth = max(320, container.bounds.width - 60 - 16)
        v.setWrapping(currentDocumentWrapped, width: estimatedWidth)
        Bench.mark("视图创建完成 换行=\(currentDocumentWrapped) 预估宽=\(Int(estimatedWidth))")
        v.setText(text)
        Bench.mark("setText 返回")
        v.setLanguage(currentLanguage)
        Bench.mark("setLanguage 返回")
        v.onTextChanged = { [weak self] in self?.markDirty() }
        v.onSelectionChanged = { [weak self] line, col in
            self?.statusRight.stringValue = "行 \(line) : 列 \(col)"
        }
        plainView = v
        install(v)
        Bench.mark("install 完成")
        selectEncodingInPopup(detected.kind)
        statusLeft.stringValue = "文本模式 · \(detected.kind.displayName) · \(detected.hasBOM ? "含 BOM" : "无 BOM") · \(formatByteCount(currentSize)) · \(v.lineStarts.count) 行" + languageSuffix()
    }

    private func switchToHexBecauseBinary(url: URL) {
        mode = .hex
        modeControl.selectedSegment = 1
        loadHex(url: url)
        statusLeft.stringValue = "检测到二进制内容，已切换为十六进制视图"
    }

    private func beginLargeMode(url: URL) {
        guard let doc = TextDocument(url: url) else {
            alertError(title: "无法打开文件", message: "无法为 \(url.lastPathComponent) 建立读取句柄。")
            return
        }
        textDocument = doc
        currentLanguage = resolveLanguage(for: url)
        let v = LargeTextEditorView(document: doc)
        v.setFontSize(fontSize)
        v.setLanguage(currentLanguage)
        v.onModified = { [weak self] in self?.markDirty() }
        v.onCaretChanged = { [weak self] line, col, offset in
            self?.statusRight.stringValue = "行 \(line) : 列 \(col)   ·   偏移 0x\(formatHex(offset))"
        }
        v.onIndexReady = { [weak self] in
            guard let self = self, let doc = self.textDocument else { return }
            self.statusLeft.stringValue = "大文件模式 · \(doc.encoding.displayName) · \(doc.newlineStyle.displayName) · \(formatByteCount(self.currentSize)) · \(doc.index.totalLines) 行" + self.languageSuffix()
        }
        largeView = v
        install(v)
        selectEncodingInPopup(doc.encoding)
        statusLeft.stringValue = "大文件模式 · 正在建立行索引…（\(formatByteCount(currentSize))）"
        v.load()
    }

    private func loadHex(url: URL) {
        guard let src = HexFileSource(url: url) else {
            alertError(title: "无法打开文件", message: "无法为 \(url.lastPathComponent) 建立读取句柄。")
            return
        }
        hexSource = src
        currentLanguage = .none
        let v = HexEditorView(source: src)
        v.setFontSize(fontSize)
        v.onModified = { [weak self] in self?.markDirty() }
        v.onCaretChanged = { [weak self] offset, count in
            var s = "偏移 0x\(formatHex(offset)) (\(offset))"
            if count > 0 { s += "   ·   选中 \(count) 字节" }
            self?.statusRight.stringValue = s
        }
        hexView = v
        install(v)
        encodingPopup.isEnabled = false
        statusLeft.stringValue = "十六进制模式 · \(formatByteCount(src.size)) · 共 \(src.totalRows) 行"
    }

    // MARK: - 状态展示

    private func updateHeader() {
        if isUntitled {
            titleLabel.stringValue = dirty ? "未命名 •" : "未命名"
            detailLabel.stringValue = "新文件尚未保存到磁盘 · 按 ⌘S 保存时选择位置"
            onTitleChange?("未命名")
            return
        }
        if let url = currentURL {
            let name = url.lastPathComponent
            titleLabel.stringValue = dirty ? "\(name) •" : name
            detailLabel.stringValue = url.deletingLastPathComponent().path
            onTitleChange?(name)
        } else {
            titleLabel.stringValue = "未打开文件"
            detailLabel.stringValue = "从左侧目录选择文件，⌘N 新建，或按 ⌘O 打开"
            onTitleChange?("")
        }
    }

    private func updateStatus() {
        guard currentURL != nil || isUntitled else {
            statusLeft.stringValue = "就绪"
            statusRight.stringValue = ""
            saveButton.isEnabled = false
            return
        }
        var parts: [String] = []
        switch mode {
        case .hex: parts.append("十六进制")
        case .text: parts.append(textDocument == nil ? "文本模式" : "大文件模式")
        }
        if mode == .text {
            parts.append(encodingPopup.titleOfSelectedItem ?? "")
        }
        if let doc = textDocument {
            parts.append("换行 \(doc.newlineStyle.displayName)")
            parts.append("\(doc.index.totalLines) 行")
        }
        if mode == .text, syntaxEnabled, currentLanguage != .none {
            parts.append("语法 \(currentLanguage.displayName)")
        }
        if mode == .text, currentDocumentWrapped {
            parts.append("自动换行")
        }
        parts.append(formatByteCount(currentSize))
        if dirty {
            parts.append("● 未保存" + (textDocument != nil ? "（\(textDocument!.editSummary)）" : ""))
        }
        statusLeft.stringValue = parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        encodingPopup.isEnabled = (mode == .text)
        saveButton.isEnabled = hasEditableDocument
    }

    private func markDirty() {
        if !dirty {
            dirty = true
            updateHeader()
        }
        updateStatus()
    }

    private func selectEncodingInPopup(_ kind: TextEncodingKind) {
        if let idx = TextEncodingKind.allCases.firstIndex(of: kind) {
            encodingPopup.selectItem(at: idx)
        }
    }

    // MARK: - 保存

    /// 是否存在可保存的文档（含未命名新文件）
    private var hasEditableDocument: Bool {
        currentURL != nil || plainView != nil || textDocument != nil || hexSource != nil
    }

    /// 将纯文本编辑器内容按当前编码（含 BOM 规则）转为字节流
    private func encodedPlainText() -> Data? {
        guard let plain = plainView else { return nil }
        guard var data = EncodingCodec.encode(plain.text, as: smallEncoding) else { return nil }
        let writeBOM = smallEncoding.alwaysWritesBOM || (smallHasBOM && !smallEncoding.bomBytes.isEmpty)
        if writeBOM { data = Data(smallEncoding.bomBytes) + data }
        return data
    }

    /// 未命名新文件在保存面板中的默认文件名（按当前语言给出扩展名）
    private func defaultNewFileName() -> String {
        let ext = currentLanguage.defaultFileExtension
        return ext.isEmpty ? "未命名.txt" : "未命名.\(ext)"
    }

    @objc private func saveTapped() { save() }

    func save() {
        // 未命名新文件：⌘S 直接走「另存为」流程选择保存位置
        if currentURL == nil {
            if isUntitled { saveAs() }
            return
        }

        do {
            if let src = hexSource {
                try src.save()
                src.reload()
                hexView?.refresh()
                dirty = false
                updateStatus()
                updateHeader()
                return
            }

            if let doc = textDocument {
                statusLeft.stringValue = "正在保存…请稍候"
                statusLeft.displayIfNeeded()
                let savedMode = mode
                try doc.save(progress: { p in
                    DispatchQueue.main.async {
                        self.statusLeft.stringValue = String(format: "正在保存… %d%%", Int(p * 100))
                    }
                })
                dirty = false
                mode = savedMode
                loadCurrent()
                flashMessage("已保存")
                return
            }

            if plainView != nil {
                guard let data = encodedPlainText() else {
                    alertError(title: "无法使用当前编码保存",
                               message: "文件包含 \(smallEncoding.displayName) 无法表示的字符。请改用 UTF-8 后重试。")
                    return
                }
                try data.write(to: currentURL!, options: .atomic)
                dirty = false
                updateStatus()
                updateHeader()
                flashMessage("已保存")
                return
            }
        } catch {
            alertError(title: "保存失败", message: error.localizedDescription)
        }
    }

    func saveAs() {
        guard hasEditableDocument else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let url = currentURL {
            panel.nameFieldStringValue = url.lastPathComponent
            panel.directoryURL = url.deletingLastPathComponent()
        } else {
            panel.nameFieldStringValue = defaultNewFileName()
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        do {
            if let src = hexSource {
                try src.save(to: dest)
            } else if let doc = textDocument {
                statusLeft.stringValue = "正在另存为…"
                statusLeft.displayIfNeeded()
                try doc.save(to: dest)
            } else if plainView != nil {
                guard let data = encodedPlainText() else {
                    alertError(title: "无法使用当前编码保存",
                               message: "内容包含 \(smallEncoding.displayName) 无法表示的字符。请改用 UTF-8 后重试。")
                    return
                }
                try data.write(to: dest, options: .atomic)
            }
            currentURL = dest
            isUntitled = false
            dirty = false
            loadCurrent()
            updateHeader()
            flashMessage("已保存到 \(dest.lastPathComponent)")
        } catch {
            alertError(title: "另存为失败", message: error.localizedDescription)
        }
    }

    private func flashMessage(_ text: String) {
        let previous = statusLeft.stringValue
        statusLeft.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if self.statusLeft.stringValue == text {
                self.statusLeft.stringValue = previous
            }
        }
    }

    // MARK: - 重新加载 / 模式

    func reloadFromDisk() {
        guard currentURL != nil else { return }
        if dirty {
            guard confirmAction(title: "放弃未保存的修改？",
                                message: "磁盘上的内容将重新载入，当前修改会丢失。",
                                okTitle: "放弃并重新载入") else { return }
        }
        dirty = false
        loadCurrent()
        flashMessage("已重新载入")
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let newMode = EditorMode(rawValue: sender.selectedSegment) ?? .text
        guard newMode != mode else { return }
        guard confirmDiscardIfNeeded() else {
            sender.selectedSegment = mode.rawValue
            return
        }
        mode = newMode
        dirty = false
        loadCurrent()
        focusEditor()
    }

    func switchMode(_ m: EditorMode) {
        guard m != mode else { return }
        modeControl.selectedSegment = m.rawValue
        modeChanged(modeControl)
    }

    // MARK: - 编码

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let kind = TextEncodingKind.allCases.first(where: { $0.displayName == title }) else { return }

        if let doc = textDocument {
            doc.setEncoding(kind)
            markDirty()
            return
        }

        guard let plain = plainView else { return }
        // 未命名新文件：没有原始字节可解码，直接切换保存编码
        guard let data = smallFileData else {
            smallEncoding = kind
            smallHasBOM = !kind.bomBytes.isEmpty
            markDirty()
            return
        }
        guard let text = EncodingCodec.decode(data, as: kind) else {
            alertError(title: "无法以该编码解码",
                       message: "文件内容不符合 \(kind.displayName)，已保持原编码。")
            selectEncodingInPopup(smallEncoding)
            return
        }
        let sel = plain.textView.selectedRange()
        smallEncoding = kind
        smallHasBOM = !kind.bomBytes.isEmpty
        plain.setText(text)
        let len = (text as NSString).length
        if sel.location <= len {
            plain.textView.setSelectedRange(NSRange(location: sel.location, length: min(sel.length, len - sel.location)))
        }
        markDirty()
    }

    // MARK: - 跳转

    @objc private func gotoTapped() {
        if mode == .hex { goToOffset() } else { goToLine() }
    }

    func goToLine() {
        guard mode == .text, currentURL != nil || plainView != nil else { return }
        let maxLine: Int
        if let doc = textDocument { maxLine = max(1, doc.displayLineCount) }
        else if let plain = plainView { maxLine = max(1, plain.lineStarts.count) }
        else { return }

        guard let input = promptString(title: "跳转到行",
                                       message: "输入行号（1 – \(maxLine)）",
                                       defaultValue: "1"),
              let line = Int(input.trimmingCharacters(in: .whitespaces)) else { return }

        if let v = largeView { v.scrollToLine(line) }
        else if let v = plainView { v.scrollToLine(line) }
    }

    func goToOffset() {
        guard currentURL != nil else { return }
        let maxOffset = max(0, currentSize - 1)
        guard let input = promptString(title: "跳转到偏移",
                                       message: "输入字节偏移（0 – \(maxOffset)），支持 0x 前缀十六进制",
                                       defaultValue: "0"),
              let offset = parseOffset(input, maxValue: maxOffset) else { return }

        if let v = hexView { v.scrollToOffset(offset) }
        else {
            switchMode(.hex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.hexView?.scrollToOffset(offset)
            }
        }
    }

    private func parseOffset(_ text: String, maxValue: Int64) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var value: Int64?
        if t.lowercased().hasPrefix("0x") {
            value = Int64(t.dropFirst(2), radix: 16)
        } else {
            value = Int64(t)
        }
        guard let v = value else { return nil }
        return Swift.min(Swift.max(0, v), maxValue)
    }

    // MARK: - 字号

    func changeFontSize(delta: CGFloat) {
        fontSize = min(30, max(9, fontSize + delta))
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = Theme.defaultFontSize
        applyFontSize()
    }

    private func applyFontSize() {
        UserDefaults.standard.set(Double(fontSize), forKey: "SUEFontSize")
        plainView?.setFontSize(fontSize)
        largeView?.setFontSize(fontSize)
        hexView?.setFontSize(fontSize)
    }

    // MARK: - 自动换行

    /// 切换「超长行自动换行」偏好（影响此后打开的文件）
    func toggleLineWrapping() {
        wrapLongLinesPreferred.toggle()
        UserDefaults.standard.set(wrapLongLinesPreferred, forKey: "SUEWrapLongLines")
        if !wrapLongLinesPreferred, let v = plainView,
           textHasLineLongerThan(v.text, limit: longLineThreshold) {
            flashMessage("当前文件含超长行，保持换行显示以免卡顿；设置已对后续文件生效")
            return
        }
        applyLineWrapping()
        flashMessage(wrapLongLinesPreferred ? "超长行自动换行：开启" : "超长行自动换行：关闭")
    }

    private func applyLineWrapping() {
        guard let v = plainView else { return }
        let need = wrapLongLinesPreferred && textHasLineLongerThan(v.text, limit: longLineThreshold)
        guard need != currentDocumentWrapped else { return }
        currentDocumentWrapped = need
        v.setWrapping(need)
        updateStatus()
    }

    // MARK: - 语法高亮

    private func resolveLanguage(for url: URL) -> SyntaxLanguage {
        guard syntaxEnabled else { return .none }
        if let forced = syntaxOverride { return forced }
        return SyntaxLanguage.detect(url: url)
    }

    private func languageSuffix() -> String {
        guard syntaxEnabled, currentLanguage != .none else { return "" }
        return "  ·  语法 \(currentLanguage.displayName)"
    }

    /// 切换语法高亮开关
    func toggleSyntaxHighlighting() {
        syntaxEnabled.toggle()
        UserDefaults.standard.set(syntaxEnabled, forKey: "SUESyntaxEnabled")
        reapplyLanguage()
    }

    /// 手动指定语言，nil 表示自动检测
    func setSyntaxLanguage(_ language: SyntaxLanguage?) {
        let wantsHighlight = (language == nil) || (language! != SyntaxLanguage.none)
        if wantsHighlight, !syntaxEnabled {
            syntaxEnabled = true
            UserDefaults.standard.set(true, forKey: "SUESyntaxEnabled")
        }
        syntaxOverride = language
        reapplyLanguage()
    }

    /// 重新按当前文件探测语言
    func reapplyLanguage() {
        guard let url = currentURL else { return }
        currentLanguage = resolveLanguage(for: url)
        plainView?.setLanguage(currentLanguage)
        largeView?.setLanguage(currentLanguage)
        updateStatus()
        flashMessage(currentLanguage == .none ? "语法高亮：关闭" : "语法高亮：\(currentLanguage.displayName)")
    }

    // MARK: - 自检辅助

    /// 自检用：模拟未命名文档输入内容后保存到指定路径（跳过保存面板），
    /// 走与 saveAs 完全相同的数据路径（编码 → BOM → 写盘 → 重新载入）。
    func runUntitledSaveTest(to dest: URL) {
        guard let plain = plainView, isUntitled else { return }
        plain.setText("未命名文档保存测试\n第二行：中文内容 abc 123\n")
        markDirty()
        guard let data = encodedPlainText() else { return }
        do {
            try data.write(to: dest, options: .atomic)
            currentURL = dest
            isUntitled = false
            dirty = false
            loadCurrent()
            updateHeader()
        } catch {
            alertError(title: "自检保存失败", message: error.localizedDescription)
        }
    }

    // MARK: - 关闭确认

    @discardableResult
    func confirmDiscardIfNeeded() -> Bool {
        guard dirty else { return true }
        let name = currentURL?.lastPathComponent ?? "未命名"
        let alert = NSAlert()
        alert.messageText = "“\(name)”已修改"
        alert.informativeText = "是否保存当前修改？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !dirty
        case .alertSecondButtonReturn:
            dirty = false
            return true
        default:
            return false
        }
    }

    func closeDocument() {
        guard confirmDiscardIfNeeded() else { return }
        currentURL = nil
        isUntitled = false
        currentLanguage = .none
        syntaxOverride = nil
        mode = .text
        modeControl.selectedSegment = 0
        teardownEditor()
        updateHeader()
        updateStatus()
    }
}

extension Theme {
    static var monoSmall: NSFont {
        return NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}
