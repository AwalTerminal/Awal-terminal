import AppKit
import AwalTerminalLib

let app = NSApplication.shared
app.setActivationPolicy(.regular)
ProcessInfo.processInfo.processName = "Awal Terminal"

let delegate = AppDelegate()
app.delegate = delegate

app.activate(ignoringOtherApps: true)
app.run()
