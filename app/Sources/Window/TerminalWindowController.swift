import AppKit

class TerminalWindowController: NSWindowController {

    init() {
        let terminalView = TerminalView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Terminal"
        window.center()
        window.contentView = terminalView
        window.makeFirstResponder(terminalView)
        window.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        window.isOpaque = true
        window.minSize = NSSize(width: 400, height: 300)

        super.init(window: window)

        terminalView.spawnShell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
