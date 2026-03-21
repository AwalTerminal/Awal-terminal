import AppKit

protocol ProfileBarDelegate: AnyObject {
    func profileBarDidSelectProfile(_ bar: ProfileBar, name: String)
    func profileBarDidRequestNew(_ bar: ProfileBar)
    func profileBarDidRequestRename(_ bar: ProfileBar)
    func profileBarDidRequestDelete(_ bar: ProfileBar)
    func profileBarDidRequestActivate(_ bar: ProfileBar)
}

class ProfileBar: NSView {
    weak var delegate: ProfileBarDelegate?

    private let popup: NSPopUpButton
    private let activeLabel: NSTextField
    private let newButton: NSButton
    private let renameButton: NSButton
    private let deleteButton: NSButton
    private let activateButton: NSButton

    private(set) var selectedProfileName: String = "Default"
    private var activeName: String = "Default"

    var selectedIsActive: Bool { selectedProfileName == activeName }

    init() {
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = Theme.barFont
        popup.translatesAutoresizingMaskIntoConstraints = false

        activeLabel = NSTextField(labelWithString: "(active)")
        activeLabel.font = Theme.barFont
        activeLabel.textColor = NSColor(red: 79.0/255.0, green: 70.0/255.0, blue: 229.0/255.0, alpha: 1)
        activeLabel.translatesAutoresizingMaskIntoConstraints = false

        newButton = ProfileBar.makeButton(title: "New", image: "plus")
        renameButton = ProfileBar.makeButton(title: "Rename", image: "pencil")
        deleteButton = ProfileBar.makeButton(title: "Delete", image: "trash")
        activateButton = ProfileBar.makeButton(title: "Activate", image: "checkmark.circle")

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBg.cgColor

        popup.target = self
        popup.action = #selector(popupChanged(_:))
        newButton.target = self
        newButton.action = #selector(newClicked(_:))
        renameButton.target = self
        renameButton.action = #selector(renameClicked(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked(_:))
        activateButton.target = self
        activateButton.action = #selector(activateClicked(_:))

        addSubview(popup)
        addSubview(activeLabel)
        addSubview(newButton)
        addSubview(renameButton)
        addSubview(deleteButton)
        addSubview(activateButton)

        // Bottom separator
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Theme.barBorder.cgColor
        addSubview(sep)

        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            activeLabel.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 4),
            activeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            newButton.leadingAnchor.constraint(equalTo: activeLabel.trailingAnchor, constant: 12),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            renameButton.leadingAnchor.constraint(equalTo: newButton.trailingAnchor, constant: 8),
            renameButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: renameButton.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            activateButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            activateButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(profiles: [String], selectedName: String, activeName: String) {
        self.activeName = activeName
        self.selectedProfileName = selectedName

        popup.removeAllItems()
        popup.addItems(withTitles: profiles)
        popup.selectItem(withTitle: selectedName)

        activeLabel.isHidden = selectedName != activeName
        activateButton.isEnabled = selectedName != activeName
        deleteButton.isEnabled = profiles.count > 1
    }

    private static func makeButton(title: String, image: String) -> NSButton {
        let btn = NSButton(title: " \(title)", target: nil, action: nil)
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.font = Theme.barFont
        btn.contentTintColor = NSColor(white: 0.70, alpha: 1)
        if let img = NSImage(systemSymbolName: image, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.imagePosition = .imageLeading
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        selectedProfileName = title
        activeLabel.isHidden = title != activeName
        activateButton.isEnabled = title != activeName
        delegate?.profileBarDidSelectProfile(self, name: title)
    }

    @objc private func newClicked(_ sender: Any?) {
        delegate?.profileBarDidRequestNew(self)
    }

    @objc private func renameClicked(_ sender: Any?) {
        delegate?.profileBarDidRequestRename(self)
    }

    @objc private func deleteClicked(_ sender: Any?) {
        delegate?.profileBarDidRequestDelete(self)
    }

    @objc private func activateClicked(_ sender: Any?) {
        delegate?.profileBarDidRequestActivate(self)
    }
}
