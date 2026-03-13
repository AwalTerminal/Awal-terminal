import AppKit
import Carbon
import CAwalTerminal

/// A dropdown "quake-style" terminal that slides from the top of the screen.
/// Activated via a global hotkey (default: Ctrl+`).
class QuickTerminalController {

    static let shared = QuickTerminalController()

    private var window: NSPanel?
    private var terminalView: TerminalView?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private let animationDuration: TimeInterval = 0.15
    private let heightRatio: CGFloat = 0.65 // 65% of screen height (square)

    private init() {}

    // MARK: - Global Hotkey

    func registerHotKey() {
        // Ctrl+` (grave accent) — keycode 50
        let hotKeyID = EventHotKeyID(signature: OSType(0x4157_4C54), id: 1) // "AWLT"
        var ref: EventHotKeyRef?
        let modifiers: UInt32 = UInt32(controlKey)

        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<QuickTerminalController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.toggle()
            }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
        eventHandler = handlerRef
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Toggle

    func toggle() {
        if let w = window, w.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Show / Hide

    private func show() {
        let panel = window ?? createWindow()
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let side = min(screenFrame.width, screenFrame.height) * heightRatio
        let visibleFrame = NSRect(
            x: screenFrame.origin.x + (screenFrame.width - side) / 2,
            y: screenFrame.origin.y + screenFrame.height - side,
            width: side,
            height: side
        )

        // Start above the screen (hidden)
        panel.setFrame(NSRect(
            x: visibleFrame.origin.x,
            y: screenFrame.origin.y + screenFrame.height,
            width: visibleFrame.width,
            height: visibleFrame.height
        ), display: false)

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        // Slide down
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(visibleFrame, display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        if let tv = terminalView {
            panel.makeFirstResponder(tv)
        }
    }

    private func hide() {
        guard let panel = window, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let targetFrame = NSRect(
            x: panel.frame.origin.x,
            y: screenFrame.origin.y + screenFrame.height,
            width: panel.frame.width,
            height: panel.frame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Window Creation

    private func createWindow() -> NSPanel {
        guard let screen = NSScreen.main else {
            fatalError("No main screen")
        }

        let side = min(screen.frame.width, screen.frame.height) * heightRatio
        let frame = NSRect(
            x: screen.frame.origin.x + (screen.frame.width - side) / 2,
            y: screen.frame.origin.y + screen.frame.height,
            width: side,
            height: side
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = AppConfig.shared.themeBg
        panel.hidesOnDeactivate = false

        let tv = TerminalView(frame: frame)
        tv.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(tv)

        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            tv.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            tv.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])

        terminalView = tv
        self.window = panel
        return panel
    }
}
