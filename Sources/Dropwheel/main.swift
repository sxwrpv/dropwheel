import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon and no main window. DROPWHEEL_REGULAR_APP=1
// runs it as a regular app, which UI automation tools can target.
let runsAsRegularApp = ProcessInfo.processInfo.environment["DROPWHEEL_REGULAR_APP"] == "1"
app.setActivationPolicy(runsAsRegularApp ? .regular : .accessory)
app.run()
