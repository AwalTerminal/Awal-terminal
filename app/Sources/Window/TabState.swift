import AppKit

class TabState {
    let splitContainer: SplitContainerView
    let statusBar: StatusBarView
    let aiSidePanel: AISidePanelView
    var customTitle: String?
    var tabColor: NSColor?
    var hasSession = false

    /// Stored constraint for animating side panel width.
    var sidePanelWidthConstraint: NSLayoutConstraint?

    var title: String {
        if let custom = customTitle { return custom }
        let model = statusBar.currentModelName.isEmpty ? "Shell" : statusBar.currentModelName
        if let path = statusBar.currentPath {
            let folder = (path as NSString).lastPathComponent
            return "\(model) — \(folder)"
        }
        return model
    }

    init(splitContainer: SplitContainerView, statusBar: StatusBarView, aiSidePanel: AISidePanelView) {
        self.splitContainer = splitContainer
        self.statusBar = statusBar
        self.aiSidePanel = aiSidePanel
    }
}
