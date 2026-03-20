import AppKit

class TabState {
    let splitContainer: SplitContainerView
    let statusBar: StatusBarView
    let aiSidePanel: AISidePanelView
    let tokenTracker = TokenTracker()
    var sessionStartTime: Date?
    var customTitle: String?
    var tabColor: NSColor?
    var hasSession = false
    var isDangerMode = false
    var worktreeInfo: WorktreeInfo?
    var remoteControlURL: String?
    var isSleepPrevented = false
    /// Set when the user manually closes the AI side panel; prevents auto-reopen.
    var userClosedAIPanel = false

    /// Stored constraint for animating side panel width.
    var sidePanelWidthConstraint: NSLayoutConstraint?

    var title: String {
        if let custom = customTitle { return custom }
        let model = statusBar.currentModelName.isEmpty ? "Shell" : statusBar.currentModelName
        if let path = statusBar.currentPath {
            let folder = (path as NSString).lastPathComponent
            if let wt = worktreeInfo, !wt.isOriginal, let branch = wt.branchName {
                return "\(model) — \(folder) [\(branch)]"
            }
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
