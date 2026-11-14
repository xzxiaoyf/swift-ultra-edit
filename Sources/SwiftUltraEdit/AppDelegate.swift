import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var mainWindowController: MainWindowController?
    private var editor: EditorViewController? { mainWindowController?.editor }

    private var syntaxMenu: NSMenu?
    private var syntaxToggleItem: NSMenuItem?
    private var syntaxLanguageItems: [NSMenuItem] = []
    private var wrapToggleItem: NSMenuItem?

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Bench.startWatchdog()
        let wc = MainWindowController()
        mainWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            wc.editor.open(url: URL(fileURLWithPath: args[i + 1]))
        }
        if args.contains("--new") {
            wc.editor.newDocument()
        }
        if let i = args.firstIndex(of: "--save-untitled-test"), i + 1 < args.count {
            let path = args[i + 1]
            wc.editor.newDocument()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                wc.editor.runUntitledSaveTest(to: URL(fileURLWithPath: path))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApp.terminate(nil)
                }
            }
        }
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            var delay = 2.0
            if let j = args.firstIndex(of: "--delay"), j + 1 < args.count, let d = Double(args[j + 1]) {
                delay = d
            }
            isCaptureMode = true
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.captureWindow(to: path)
            }
        }

        // 应用启动前已缓存的"打开方式"文件事件
        if !pendingOpenURLs.isEmpty {
            diagLog("窗口就绪，处理缓存的 \(pendingOpenURLs.count) 个待打开文件")
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            handleOpen(urls: urls)
        }
    }

    private var isCaptureMode = false

    private func captureWindow(to path: String) {
        defer { NSApp.terminate(nil) }
        NSApp.appearance = NSAppearance(named: .aqua)
        guard let window = mainWindowController?.window,
              let view = window.contentView else { return }
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("screenshot -> \(path) (\(Int(bounds.width))x\(Int(bounds.height)))")

        // 调试：视图树 frame 概览
        if ProcessInfo.processInfo.environment["SUE_DEBUG"] != nil {
            func dump(_ v: NSView, _ depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                print("\(pad)\(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden)")
                for s in v.subviews { dump(s, depth + 1) }
            }
            if let content = window.contentView { dump(content, 0) }
        }

        // 调试：遍历查找特定视图（避免递归闭包的类型推断问题）
        var queue: [NSView] = []
        if let c = window.contentView { queue.append(c) }
        var foundTextView: NSTextView? = nil
        var foundCanvas: NSView? = nil
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if foundTextView == nil, let t = v as? NSTextView { foundTextView = t }
            let n = String(describing: type(of: v))
            if foundCanvas == nil, (n.contains("TextCanvasView") || n.contains("HexCanvasView")) { foundCanvas = v }
            queue.append(contentsOf: v.subviews)
        }

        // 用 PDF 渲染路径验证 NSTextView 内容（cacheDisplay 对 layer 化视图可能跳过文字层）
        if let tv = foundTextView {
            print("NSTextView length=\(tv.string.count) glyphs=\(tv.layoutManager?.numberOfGlyphs ?? -1)")
            let pdf = tv.dataWithPDF(inside: tv.bounds)
            try? pdf.write(to: URL(fileURLWithPath: "/tmp/sue_textview.pdf"))
            print("textview pdf -> /tmp/sue_textview.pdf (\(pdf.count) bytes)")
        }

        if let canvas = foundCanvas {
            canvas.layoutSubtreeIfNeeded()
            canvas.needsDisplay = true
            var cb = canvas.bounds
            if cb.height > 3000 {
                // 只截取顶部可见区域，避免超高位图
                cb = NSRect(x: 0, y: 0, width: cb.width, height: min(600, cb.height))
            }
            print("canvas bounds=\(canvas.bounds) capture=\(cb)")
            if cb.width > 0, cb.height > 0,
               let crep = canvas.bitmapImageRepForCachingDisplay(in: cb) {
                canvas.cacheDisplay(in: cb, to: crep)
                if let cdata = crep.representation(using: .png, properties: [:]) {
                    let cpath = path.replacingOccurrences(of: ".png", with: "-canvas.png")
                    try? cdata.write(to: URL(fileURLWithPath: cpath))
                    print("canvas screenshot -> \(cpath)")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCaptureMode { return .terminateNow }
        guard let editor = editor, editor.hasUnsavedChanges else { return .terminateNow }
        return editor.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        diagLog("application(open:) 调用，共 \(urls.count) 个文件，窗口控制器存在=\(mainWindowController != nil)")
        handleOpen(urls: urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        diagLog("application(openFile:) 调用，窗口控制器存在=\(mainWindowController != nil)")
        handleOpen(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    /// 诊断输出（设置 SUE_DIAG=/path/file.log 环境变量时启用）
    private func diagLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SUE_DIAG"] else { return }
        let text = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 访达"打开方式"可能在 applicationDidFinishLaunching 之前派发文件事件，
    /// 此时主窗口尚未创建——先缓存，等窗口就绪后再打开。
    private var pendingOpenURLs: [URL] = []

    private func handleOpen(urls: [URL]) {
        diagLog("handleOpen: wc=\(mainWindowController != nil) urls=\(urls.map { $0.lastPathComponent })")
        guard let editor = mainWindowController?.editor else {
            pendingOpenURLs.append(contentsOf: urls)
            diagLog("窗口未就绪，已缓存 \(pendingOpenURLs.count) 个待打开文件")
            return
        }
        if let first = urls.first {
            editor.open(url: first)
        }
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 菜单动作

    @objc private func newFileAction(_ sender: Any?) {
        editor?.newDocument()
    }

    @objc private func openFileAction(_ sender: Any?) {
        editor?.showOpenPanel()
    }

    @objc private func openFolderAction(_ sender: Any?) {
        guard let sidebar = mainWindowController?.sidebar else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "选择左侧文件列表的根目录"
        if panel.runModal() == .OK, let url = panel.url {
            sidebar.setRoot(url)
        }
    }

    @objc private func saveAction(_ sender: Any?) {
        editor?.save()
    }

    @objc private func saveAsAction(_ sender: Any?) {
        editor?.saveAs()
    }

    @objc private func reloadAction(_ sender: Any?) {
        editor?.reloadFromDisk()
    }

    @objc private func closeFileAction(_ sender: Any?) {
        editor?.closeDocument()
    }

    @objc private func goToLineAction(_ sender: Any?) {
        editor?.goToLine()
    }

    @objc private func goToOffsetAction(_ sender: Any?) {
        editor?.goToOffset()
    }

    @objc private func textModeAction(_ sender: Any?) {
        editor?.switchMode(.text)
    }

    @objc private func hexModeAction(_ sender: Any?) {
        editor?.switchMode(.hex)
    }

    @objc private func increaseFontAction(_ sender: Any?) {
        editor?.changeFontSize(delta: 1)
    }

    @objc private func decreaseFontAction(_ sender: Any?) {
        editor?.changeFontSize(delta: -1)
    }

    @objc private func resetFontAction(_ sender: Any?) {
        editor?.resetFontSize()
    }

    @objc private func toggleSyntaxAction(_ sender: Any?) {
        editor?.toggleSyntaxHighlighting()
    }

    @objc private func toggleWrapAction(_ sender: Any?) {
        editor?.toggleLineWrapping()
    }

    @objc private func autoDetectLanguageAction(_ sender: Any?) {
        editor?.setSyntaxLanguage(nil)
    }

    @objc private func chooseLanguageAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = SyntaxLanguage(rawValue: raw) else { return }
        editor?.setSyntaxLanguage(language)
    }

    @objc private func toggleSidebarAction(_ sender: Any?) {
        mainWindowController?.toggleSidebar()
    }

    // MARK: - 菜单构建

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 SwiftUltraEdit",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "隐藏 SwiftUltraEdit",
                                       action: #selector(NSApplication.hide(_:)),
                                       keyEquivalent: "h")
        hideItem.target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 SwiftUltraEdit",
                                       action: #selector(NSApplication.terminate(_:)),
                                       keyEquivalent: "q")
        quitItem.target = NSApp

        // 文件
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu

        addItem(to: fileMenu, title: "新建文件", action: #selector(newFileAction(_:)), key: "n")
        addItem(to: fileMenu, title: "打开文件…", action: #selector(openFileAction(_:)), key: "o")
        addItem(to: fileMenu, title: "打开文件夹…", action: #selector(openFolderAction(_:)), key: "o", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "保存", action: #selector(saveAction(_:)), key: "s")
        addItem(to: fileMenu, title: "另存为…", action: #selector(saveAsAction(_:)), key: "s", modifiers: [.command, .option])
        addItem(to: fileMenu, title: "重新载入", action: #selector(reloadAction(_:)), key: "r")
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "关闭文件", action: #selector(closeFileAction(_:)), key: "w", modifiers: [.command, .shift])
        let closeWindow = fileMenu.addItem(withTitle: "关闭窗口",
                                           action: #selector(NSWindow.performClose(_:)),
                                           keyEquivalent: "w")
        closeWindow.target = nil

        // 编辑
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu

        let undo = editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undo.target = nil
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = nil
        editMenu.addItem(.separator())
        for (title, sel, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = editMenu.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key)
            item.target = nil
        }
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: "查找…",
                                        action: #selector(NSTextView.performTextFinderAction(_:)),
                                        keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        findItem.target = nil

        // 导航
        let navItem = NSMenuItem()
        mainMenu.addItem(navItem)
        let navMenu = NSMenu(title: "导航")
        navItem.submenu = navMenu
        addItem(to: navMenu, title: "跳转到行…", action: #selector(goToLineAction(_:)), key: "l")
        addItem(to: navMenu, title: "跳转到偏移…", action: #selector(goToOffsetAction(_:)), key: "l", modifiers: [.command, .shift])

        // 视图
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        viewItem.submenu = viewMenu
        addItem(to: viewMenu, title: "文本模式", action: #selector(textModeAction(_:)), key: "1")
        addItem(to: viewMenu, title: "十六进制模式", action: #selector(hexModeAction(_:)), key: "2")
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, title: "放大字号", action: #selector(increaseFontAction(_:)), key: "=")
        addItem(to: viewMenu, title: "缩小字号", action: #selector(decreaseFontAction(_:)), key: "-")
        addItem(to: viewMenu, title: "还原默认字号", action: #selector(resetFontAction(_:)), key: "0")
        viewMenu.addItem(.separator())

        let toggleSyntax = viewMenu.addItem(withTitle: "启用语法高亮",
                                            action: #selector(toggleSyntaxAction(_:)),
                                            keyEquivalent: "h")
        toggleSyntax.keyEquivalentModifierMask = [.command, .shift]
        toggleSyntax.target = self
        syntaxToggleItem = toggleSyntax

        let wrapItem = viewMenu.addItem(withTitle: "超长行自动换行",
                                        action: #selector(toggleWrapAction(_:)),
                                        keyEquivalent: "w")
        wrapItem.keyEquivalentModifierMask = [.command, .option]
        wrapItem.target = self
        wrapToggleItem = wrapItem

        let languageRoot = NSMenuItem(title: "语法语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: "语法语言")
        languageMenu.delegate = self
        languageRoot.submenu = languageMenu
        viewMenu.addItem(languageRoot)
        syntaxMenu = languageMenu

        let autoItem = languageMenu.addItem(withTitle: "自动检测",
                                            action: #selector(autoDetectLanguageAction(_:)),
                                            keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = "auto"
        syntaxLanguageItems = [autoItem]

        languageMenu.addItem(.separator())
        for language in SyntaxLanguage.selectable {
            let item = languageMenu.addItem(withTitle: language.displayName,
                                            action: #selector(chooseLanguageAction(_:)),
                                            keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            syntaxLanguageItems.append(item)
        }
        languageMenu.addItem(.separator())
        let plainItem = languageMenu.addItem(withTitle: "纯文本（不高亮）",
                                             action: #selector(chooseLanguageAction(_:)),
                                             keyEquivalent: "")
        plainItem.target = self
        plainItem.representedObject = SyntaxLanguage.none.rawValue
        syntaxLanguageItems.append(plainItem)

        viewMenu.delegate = self
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, title: "显示 / 隐藏侧边栏", action: #selector(toggleSidebarAction(_:)), key: "s", modifiers: [.control, .command])

        // 窗口
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        let min_ = windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        min_.target = nil
        let zoom = windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoom.target = nil
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        syntaxToggleItem?.state = (editor?.syntaxEnabled ?? true) ? .on : .off
        wrapToggleItem?.state = (editor?.wrapLongLinesPreferred ?? true) ? .on : .off
        let current = editor?.currentLanguage
        let isAuto = editor?.usesAutoSyntax ?? true
        for item in syntaxLanguageItems {
            guard let raw = item.representedObject as? String else { continue }
            if raw == "auto" {
                item.state = isAuto ? .on : .off
            } else {
                item.state = (!isAuto && raw == current?.rawValue) ? .on : .off
            }
        }
    }

    private func addItem(to menu: NSMenu,
                         title: String,
                         action: Selector,
                         key: String,
                         modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
    }
}
