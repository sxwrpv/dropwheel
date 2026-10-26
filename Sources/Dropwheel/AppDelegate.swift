import AppKit
import DropwheelCore
import DropwheelEngines

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let shelf = FloatShelf()
    private let wheel = WheelPanelController()
    private let jobs = JobCenter()
    private let toolOptions = ToolOptionsPanel()
    private let editors = EditorWindows()
    private lazy var jobPanel = JobPanel(center: jobs)
    private lazy var dragMonitor = DragMonitor(bindings: preferences.keyBindings)
    private lazy var actions = FileActionPerformer(shelf: shelf, preferences: preferences)
    private var statusItem: NSStatusItem?
    /// What is being dragged, read once when the first wheel of a drag opens.
    private var dragSelection: [SelectionItem]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()

        wheel.onDrop = { [weak self] item, urls in
            self?.handleDrop(item, urls: urls)
        }
        dragMonitor.onEvent = { [weak self] event in
            self?.handle(event)
        }
        dragMonitor.start()
        _ = jobPanel
        #if DEBUG
        showPreviewWheelIfRequested()
        #endif
    }

    #if DEBUG
    /// Development aid, debug builds only: `DROPWHEEL_PREVIEW_WHEEL=actions` opens that wheel at
    /// launch, so drops can be tested without holding a key mid-drag.
    /// `DROPWHEEL_PREVIEW_FILES=/a.png:/b.heic` stands in for the dragged files,
    /// and `DROPWHEEL_PREVIEW_CONVERT=jpg` queues them as if dropped on that slice.
    private func showPreviewWheelIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        let files = (environment["DROPWHEEL_PREVIEW_FILES"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        if let raw = environment["DROPWHEEL_PREVIEW_WHEEL"], let kind = WheelKind(rawValue: raw) {
            if !files.isEmpty { dragSelection = files.map(ConversionService.selectionItem) }
            handle(.showWheel(kind))
        }
        if let raw = environment["DROPWHEEL_PREVIEW_TOOL"], let tool = ToolKind(rawValue: raw), !files.isEmpty {
            handleDrop(WheelItem.tool(tool), urls: files)
        }
        if let raw = environment["DROPWHEEL_PREVIEW_CONVERT"], let format = FileFormat(rawValue: raw), !files.isEmpty {
            handleDrop(WheelItem.conversion(to: format), urls: files)
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard actions.isBusy || jobs.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = actions.isBusy ? "Dropwheel is still moving files" : "Dropwheel is still converting files"
        alert.informativeText = actions.isBusy
            ? "Quitting now can leave a partial copy at the destination."
            : "Quitting now stops the conversions that haven’t finished."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
        // Child processes outlive the app, so stop them and remove their
        // half-written files rather than leaving ffmpeg running.
        jobs.cancelAll()
        ProcessRunner.terminateAll()
        ConversionService.discardWorkInProgress()
    }

    private func handle(_ event: DragSessionEvent) {
        switch event {
        case .showWheel(let kind):
            let selection = currentDragSelection()
            let key = preferences.keyBindings.key(for: kind)
            wheel.show(kind, keySymbol: key.symbol,
                       items: WheelCatalog.items(for: kind, selection: selection, capabilities: .system),
                       emptyMessage: Self.emptyMessage(for: kind))
        case .dragEnded:
            dragSelection = nil
            wheel.hideSoon()
        }
    }

    /// Reads the dragged files once per drag. An empty read isn't cached, in
    /// case the drag pasteboard was still being filled.
    private func currentDragSelection() -> [SelectionItem] {
        if let dragSelection { return dragSelection }
        let selection = dragMonitor.draggedFileURLs().map(ConversionService.selectionItem)
        if !selection.isEmpty { dragSelection = selection }
        return selection
    }

    private static func emptyMessage(for kind: WheelKind) -> String {
        switch kind {
        case .conversions: "No shared formats"
        case .tools: "No tools for this selection"
        case .actions: ""
        }
    }

    private func handleDrop(_ item: WheelItem, urls: [URL]) {
        switch item.action {
        case .fileAction(let kind):
            actions.perform(kind, on: urls)
        case .convert(let format):
            jobs.convert(urls, to: format)
        case .tool(let kind):
            runTool(kind, on: urls)
        }
    }

    /// Tools with choices ask first; the rest run straight away.
    private func runTool(_ kind: ToolKind, on urls: [URL]) {
        if kind.opensEditor {
            // One editor per file; each saves its own copy.
            for url in urls {
                editors.open(tool: kind, url: url) { [weak self] options in
                    self?.jobs.runTool(kind, on: [url], options: options)
                }
            }
            return
        }
        guard kind.needsOptions else {
            jobs.runTool(kind, on: urls, options: .none)
            return
        }
        // PDFs can only be compressed with presets, not to a size, so a size
        // goal is offered only when no file in the selection is a PDF.
        let allowsSizeGoals = !urls.contains { FileFormat(fileName: $0.lastPathComponent) == .pdf }
        let fileCount = kind.usesWholeSelection ? 1 : urls.count
        toolOptions.present(tool: kind, fileCount: fileCount, allowsSizeGoals: allowsSizeGoals) { [weak self] options in
            self?.jobs.runTool(kind, on: urls, options: options)
        }
    }

    // MARK: Menu bar

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Dropwheel")
        item.menu = makeMenu()
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let bindings = preferences.keyBindings
        let hint = WheelKind.allCases
            .map { "\(bindings.key(for: $0).symbol) \($0.title)" }
            .joined(separator: "   ")
        menu.addItem(disabledItem("Drag a file, then tap a key:"))
        menu.addItem(disabledItem(hint))
        menu.addItem(.separator())

        menu.addItem(withTitle: "Show Float Shelf", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.addItem(makeTerminalMenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dropwheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func makeTerminalMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Open Folders In", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for app in TerminalApp.allCases {
            let item = NSMenuItem(title: app.title, action: #selector(chooseTerminal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.rawValue
            item.state = app == preferences.terminalApp ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func showShelf() {
        shelf.show()
    }

    @objc private func chooseTerminal(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let app = TerminalApp(rawValue: raw) else { return }
        preferences.terminalApp = app
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
    }
}
