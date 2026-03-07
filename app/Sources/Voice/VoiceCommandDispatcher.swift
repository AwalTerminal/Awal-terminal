import AppKit
import CAwalTerminal

/// Executes voice actions by calling existing window controller / terminal view methods.
class VoiceCommandDispatcher {

    /// Dispatch a voice action to the appropriate handler.
    /// Returns true if the action was handled.
    @discardableResult
    func dispatch(_ action: VoiceAction, windowController: TerminalWindowController) -> Bool {
        switch action {
        case .scrollUp:
            scrollViewport(windowController: windowController, delta: 10)
        case .scrollDown:
            scrollViewport(windowController: windowController, delta: -10)
        case .scrollToTop:
            scrollViewport(windowController: windowController, delta: 10000)
        case .scrollToBottom:
            scrollViewport(windowController: windowController, delta: -10000)
        case .clear:
            windowController.injectBytesToFocusedTerminal([0x0C]) // Ctrl+L
        case .newTab:
            windowController.newTab(nil)
        case .closeTab:
            windowController.closeTab(nil)
        case .nextTab:
            windowController.selectNextTab(nil)
        case .previousTab:
            windowController.selectPreviousTab(nil)
        case .switchTab(let n):
            windowController.switchToTab(at: n - 1)
        case .splitRight:
            windowController.splitRight(nil)
        case .splitDown:
            windowController.splitDown(nil)
        case .closePane:
            windowController.closePane(nil)
        case .toggleSidePanel:
            windowController.toggleAISidePanel(nil)
        case .cancel:
            windowController.injectBytesToFocusedTerminal([0x03]) // Ctrl+C
        case .find(let query):
            windowController.findInTerminal(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                windowController.setSearchQueryInFocusedTerminal(query)
            }
        }
        return true
    }

    // MARK: - Private

    private func scrollViewport(windowController: TerminalWindowController, delta: Int32) {
        windowController.scrollFocusedTerminal(delta: delta)
    }
}
