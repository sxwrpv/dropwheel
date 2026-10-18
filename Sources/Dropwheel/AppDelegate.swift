import AppKit
import DropwheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let shelf = FloatShelf()
    private let wheel = WheelPanelController()
    private lazy var dragMonitor = DragMonitor(bindings: preferences.keyBindings)
    private lazy var actions = FileActionPerformer(shelf: shelf, preferences: preferences)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()

        wheel.onDrop = { [weak self] item, urls in
            self?.handleDrop(item, urls: urls)
        }
        dragMonitor.onEvent = { [weak self] event in
            self?.handle(event)
        }
        dragMonitor.start()
        showPreviewWheelIfRequested()
    }

    /// Development aid: `DROPWHEEL_PREVIEW_WHEEL=actions` opens that wheel at
    /// launch, so drops can be tested without holding a key mid-drag.
    private func showPreviewWheelIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["DROPWHEEL_PREVIEW_WHEEL"],
              let kind = WheelKind(rawValue: raw) else { return }
        handle(.showWheel(kind))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard actions.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Dropwheel is still moving files"
        alert.informativeText = "Quitting now can leave a partial copy at the destination."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
    }

    private func handle(_ event: DragSessionEvent) {
        switch event {
        case .showWheel(let kind):
            let key = preferences.keyBindings.key(for: kind)
            wheel.show(kind, keySymbol: key.symbol, items: WheelCatalog.items(for: kind))
        case .dragEnded:
            wheel.hideSoon()
        }
    }

    private func handleDrop(_ item: WheelItem, urls: [URL]) {
        switch item.action {
        case .fileAction(let kind):
            actions.perform(kind, on: urls)
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
