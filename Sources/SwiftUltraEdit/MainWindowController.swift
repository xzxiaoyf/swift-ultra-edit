import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {

    let sidebar = SidebarViewController()
    let editor = EditorViewController()
    private var splitController: NSSplitViewController?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "SwiftUltraEdit"
        window.minSize = NSSize(width: 760, height: 480)
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SwiftUltraEditMainWindow")
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        let split = NSSplitViewController()

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 200
        sideItem.maximumThickness = 560
        sideItem.canCollapse = true
        sideItem.holdingPriority = NSLayoutConstraint.Priority(260)
        split.addSplitViewItem(sideItem)

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 420
        split.addSplitViewItem(editorItem)

        splitController = split
        window?.contentViewController = split
        window?.delegate = self

        sidebar.onOpenFile = { [weak self] url in
            self?.editor.open(url: url)
        }
        editor.onTitleChange = { [weak self] name in
            guard let self = self else { return }
            self.window?.title = name.isEmpty ? "SwiftUltraEdit" : "\(name) — SwiftUltraEdit"
        }
    }

    func toggleSidebar() {
        splitController?.splitViewItems.first?.isCollapsed.toggle()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return editor.confirmDiscardIfNeeded()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(nil)
    }
}
