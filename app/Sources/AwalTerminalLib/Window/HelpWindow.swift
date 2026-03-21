import AppKit
import WebKit

class HelpWindow: NSWindowController {

    private static var shared: HelpWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = HelpWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Awal Terminal Help"
        window.minSize = NSSize(width: 500, height: 400)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg
        window.center()

        self.init(window: window)
        window.delegate = self

        let webView = WKWebView(frame: window.contentView!.bounds)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")

        if let url = Self.documentationURL() {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        window.contentView = webView
    }

    private static func documentationURL() -> URL? {
        // 1. Try bundle (works in .app)
        if let bundled = Bundle.main.url(forResource: "documentation", withExtension: "html") {
            return bundled
        }
        // 2. Fallback: walk up from executable to find docs/documentation.html (swift run)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("docs/documentation.html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

// MARK: - NSWindowDelegate

extension HelpWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        HelpWindow.shared = nil
    }
}
