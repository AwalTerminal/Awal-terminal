import AppKit

class TerminalWindowTracker {

    static let shared = TerminalWindowTracker()

    private var controllers: [TerminalWindowController] = []

    private init() {}

    func register(_ controller: TerminalWindowController) {
        controllers.append(controller)
    }

    func remove(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    var count: Int { controllers.count }

    var allControllers: [TerminalWindowController] { controllers }
}
