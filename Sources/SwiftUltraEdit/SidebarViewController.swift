import AppKit

// MARK: - 树节点

final class FileNode {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var didLoadChildren = false

    init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    func loadChildren(showHidden: Bool, showPackages: Bool) -> [FileNode] {
        if didLoadChildren, let c = children { return c }
        guard isDirectory else {
            children = []
            didLoadChildren = true
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [])) ?? []
        var nodes: [FileNode] = []
        nodes.reserveCapacity(items.count)
        for u in items {
            let name = u.lastPathComponent
            if !showHidden && name.hasPrefix(".") { continue }
            let values = try? u.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if !showHidden && name == "node_modules" { continue }
            if let values = values, values.isPackage == true && !showPackages && values.isDirectory == true {
                // 保留 .app 等包（能进二进制查看），但默认仍作为普通文件呈现
            }
            nodes.append(FileNode(url: u))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        children = nodes
        didLoadChildren = true
        return nodes
    }

    func invalidate() {
        children = nil
        didLoadChildren = false
    }
}

// MARK: - 侧栏

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let pathLabel = NSTextField(labelWithString: "未选择目录")
    private let infoLabel = NSTextField(labelWithString: "")
    private let rootButton = NSButton(title: "选择目录…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)

    private var rootNode: FileNode?
    var onOpenFile: ((URL) -> Void)?

    var rootURL: URL? { rootNode?.url }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        let saved = UserDefaults.standard.string(forKey: "SidebarRootPath")
        let candidate = saved.flatMap { URL(fileURLWithPath: $0) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop")
        var start = candidate ?? home
        if saved == nil, FileManager.default.fileExists(atPath: desktop.path) { start = desktop }
        if !FileManager.default.fileExists(atPath: start.path) { start = home }
        setRoot(start)
    }

    private func setupUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "文件"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.floatsGroupRows = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        pathLabel.font = Theme.uiFont(size: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        infoLabel.font = Theme.uiFont(size: 10)
        infoLabel.textColor = .tertiaryLabelColor

        rootButton.bezelStyle = .rounded
        rootButton.controlSize = .small
        rootButton.font = Theme.uiFont(size: 11)
        rootButton.target = self
        rootButton.action = #selector(chooseRoot)

        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.font = Theme.uiFont(size: 11)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTree)

        let buttons = NSStackView(views: [rootButton, refreshButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [pathLabel, infoLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(labels)
        header.addSubview(buttons)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 48),

            labels.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - 根目录

    func setRoot(_ url: URL) {
        let node = FileNode(url: url)
        rootNode = node
        pathLabel.stringValue = url.path
        pathLabel.toolTip = url.path
        outlineView.reloadData()
        updateInfo()
        UserDefaults.standard.set(url.path, forKey: "SidebarRootPath")
    }

    private func updateInfo() {
        guard let node = rootNode else { infoLabel.stringValue = ""; return }
        let count = node.loadChildren(showHidden: false, showPackages: false).count
        infoLabel.stringValue = "\(count) 个项目"
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择用于浏览的根目录"
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url)
        }
    }

    @objc private func refreshTree() {
        guard let node = rootNode else { return }
        node.invalidate()
        invalidateRecursively(node)
        outlineView.reloadData()
        updateInfo()
    }

    private func invalidateRecursively(_ node: FileNode) {
        let kids = node.children ?? []
        node.invalidate()
        for child in kids { invalidateRecursively(child) }
    }

    // MARK: - 打开

    @objc private func outlineClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onOpenFile?(node.url)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else {
            return rootNode?.loadChildren(showHidden: false, showPackages: false).count ?? 0
        }
        return node.loadChildren(showHidden: false, showPackages: false).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode {
            let children = node.loadChildren(showHidden: false, showPackages: false)
            return children[index]
        }
        let children = rootNode?.loadChildren(showHidden: false, showPackages: false) ?? []
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        var cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = id
            let img = NSImageView()
            img.translatesAutoresizingMaskIntoConstraints = false
            img.imageScaling = .scaleProportionallyDown
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = Theme.uiFont(size: 12)
            c.addSubview(img)
            c.addSubview(tf)
            c.imageView = img
            c.textField = tf
            NSLayoutConstraint.activate([
                img.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                img.widthAnchor.constraint(equalToConstant: 16),
                img.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            cell = c
        }
        cell?.textField?.stringValue = node.url.lastPathComponent
        cell?.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell?.toolTip = node.url.path
        return cell
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return index >= 0 && index < count ? self[index] : nil
    }
}
