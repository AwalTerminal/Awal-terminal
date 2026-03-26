import AppKit

class TabGroup {
    let id: UUID
    var name: String
    var color: NSColor?
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, color: NSColor? = nil, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}
