import AppKit

class TabState {
    let splitContainer: SplitContainerView
    let statusBar: StatusBarView
    var customTitle: String?

    var title: String {
        if let custom = customTitle { return custom }
        let model = statusBar.currentModelName.isEmpty ? "Shell" : statusBar.currentModelName
        if let path = statusBar.currentPath {
            let folder = (path as NSString).lastPathComponent
            return "\(model) — \(folder)"
        }
        return model
    }

    init(splitContainer: SplitContainerView, statusBar: StatusBarView) {
        self.splitContainer = splitContainer
        self.statusBar = statusBar
    }
}
