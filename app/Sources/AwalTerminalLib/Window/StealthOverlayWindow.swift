import AppKit
import QuartzCore

class StealthOverlayWindow {

    static let shared = StealthOverlayWindow()

    private var windows: [NSWindow] = []
    private(set) var isActive = false
    private var previousKeyWindow: NSWindow?
    private var eventMonitor: Any?

    private init() {
        // Safety net: unhide cursor on app termination in case dismiss() never runs
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            if self?.isActive == true {
                NSCursor.unhide()
            }
        }
    }

    func activate() {
        guard !isActive else { return }
        let isSleepPrevented = TerminalWindowTracker.shared.allControllers.contains { controller in
            controller.tabs.contains { $0.isSleepPrevented }
        }
        guard isSleepPrevented else { return }

        isActive = true
        previousKeyWindow = NSApp.keyWindow

        for screen in NSScreen.screens {
            let window = StealthWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.acceptsMouseMovedEvents = true
            window.hasShadow = false
            window.alphaValue = 1.0

            let contentView = StealthContentView(frame: screen.frame)
            contentView.onDismiss = { [weak self] in self?.dismiss() }
            window.contentView = contentView

            // Add breathing LED on the primary screen (starts after intro fades)
            if screen == NSScreen.screens.first {
                let ledView = BreathingLEDView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
                ledView.translatesAutoresizingMaskIntoConstraints = false
                ledView.alphaValue = 0
                contentView.addSubview(ledView)
                NSLayoutConstraint.activate([
                    ledView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    ledView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -60),
                    ledView.widthAnchor.constraint(equalToConstant: 8),
                    ledView.heightAnchor.constraint(equalToConstant: 8),
                ])
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    // Skip intro animation, show LED immediately
                    ledView.alphaValue = 1.0
                    ledView.layer?.opacity = 0.6
                } else {
                    showIntroOverlay(in: contentView, ledView: ledView)
                }
            }

            // Post accessibility announcement
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: "Stealth mode activated. Press any key to return.",
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )

            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(contentView)
            windows.append(window)
        }

        NSCursor.hide()

        // Monitor events as backup dismissal
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.dismiss()
            return nil
        }
    }

    private func showIntroOverlay(in contentView: NSView, ledView: BreathingLEDView) {
        let titleLabel = NSTextField(labelWithString: "AWAL TERMINAL")
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        titleLabel.attributedStringValue = NSAttributedString(
            string: "AWAL TERMINAL",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: NSColor.white,
                .kern: 6.0,
                .paragraphStyle: titleParagraph,
            ]
        )

        let separator = NSTextField(labelWithString: "─────────────────────")
        separator.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        separator.textColor = NSColor.white.withAlphaComponent(0.4)
        separator.alignment = .center

        let bodyLabel = NSTextField(labelWithString: "Going dark.\nYour session is safe.")
        bodyLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 0

        let hintLabel = NSTextField(labelWithString: "Press any key to return.")
        hintLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        hintLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, separator, bodyLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(16, after: separator)
        stack.setCustomSpacing(24, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alphaValue = 0

        // Add glow effect via shadow
        stack.wantsLayer = true
        stack.shadow = NSShadow()
        stack.layer?.shadowColor = NSColor.white.withAlphaComponent(0.3).cgColor
        stack.layer?.shadowRadius = 20
        stack.layer?.shadowOpacity = 1
        stack.layer?.shadowOffset = .zero

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        // Fade in (0.3s)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            stack.animator().alphaValue = 1.0
        }, completionHandler: {
            // Hold for 2s, then fade out (0.8s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.8
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    stack.animator().alphaValue = 0.0
                }, completionHandler: {
                    stack.removeFromSuperview()
                    // Now show the LED and start breathing
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.3
                        ledView.animator().alphaValue = 1.0
                    })
                    ledView.startBreathing()
                })
            }
        })
    }

    func dismiss() {
        guard isActive else { return }
        isActive = false

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        NSCursor.unhide()

        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            for window in windows {
                window.animator().alphaValue = 0.0
            }
        }, completionHandler: { [self] in
            for window in windows {
                window.orderOut(nil)
            }
            windows.removeAll()

            if let prev = previousKeyWindow, prev.isVisible {
                prev.makeKeyAndOrderFront(nil)
            }
            previousKeyWindow = nil
        })
    }
}

// MARK: - Stealth Window (borderless but can become key)

private class StealthWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Stealth Content View

private class StealthContentView: NSView {

    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onDismiss?()
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

// MARK: - Breathing LED View

private class BreathingLEDView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func startBreathing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.0
        animation.toValue = 1.0
        animation.duration = 1.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "breathing")
    }
}
