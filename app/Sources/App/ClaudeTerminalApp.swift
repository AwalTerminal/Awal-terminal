import AppKit
import CAwalTerminal

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationDidFinishLaunching(_ notification: Notification) {
        at_init_logging()

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        setupMainMenu()

        let controller = TerminalWindowController(isInitialTab: true)
        TerminalWindowTracker.shared.register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func toggleNotifications(_ sender: Any?) {
        NotificationManager.shared.isEnabled.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleNotifications(_:)) {
            menuItem.state = NotificationManager.shared.isEnabled ? .on : .off
        }
        return true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Awal Terminal")
        appMenu.addItem(withTitle: "About Awal Terminal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Awal Terminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(TerminalWindowController.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Awal Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        shellMenu.addItem(newTabItem)

        let renameTabItem = NSMenuItem(title: "Rename Tab…", action: #selector(TerminalWindowController.renameTab(_:)), keyEquivalent: "r")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(renameTabItem)

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        shellMenu.addItem(closeTabItem)

        shellMenu.addItem(NSMenuItem.separator())

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(TerminalWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(TerminalWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(prevTabItem)

        shellMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(TerminalWindowController.findInTerminal(_:)), keyEquivalent: "f")
        shellMenu.addItem(findItem)

        shellMenu.addItem(NSMenuItem.separator())

        let splitRightItem = NSMenuItem(title: "Split Right", action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "d")
        shellMenu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDownItem)

        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(TerminalWindowController.closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(closePaneItem)

        shellMenu.addItem(NSMenuItem.separator())

        let nextPaneItem = NSMenuItem(title: "Next Pane", action: #selector(TerminalWindowController.focusNextPane(_:)), keyEquivalent: "]")
        shellMenu.addItem(nextPaneItem)

        let prevPaneItem = NSMenuItem(title: "Previous Pane", action: #selector(TerminalWindowController.focusPreviousPane(_:)), keyEquivalent: "[")
        shellMenu.addItem(prevPaneItem)

        shellMenu.addItem(NSMenuItem.separator())

        let notifItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        shellMenu.addItem(notifItem)

        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        ProcessInfo.processInfo.processName = "Awal Terminal"

        let delegate = AppDelegate()
        app.delegate = delegate

        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
