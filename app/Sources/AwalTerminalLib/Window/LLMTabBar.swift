import AppKit

protocol LLMTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: LLMTabBar, didSelectModel model: LLMModel)
}

class LLMTabBar: NSView {
    weak var delegate: LLMTabBarDelegate?

    private let segmentedControl: NSSegmentedControl
    private let models: [LLMModel]

    var selectedModel: LLMModel? {
        let idx = segmentedControl.selectedSegment
        guard idx >= 0, idx < models.count else { return nil }
        return models[idx]
    }

    init() {
        models = ModelCatalog.configurable

        segmentedControl = NSSegmentedControl()
        segmentedControl.segmentCount = models.count
        segmentedControl.segmentStyle = .capsule
        segmentedControl.trackingMode = .selectOne
        for (i, model) in models.enumerated() {
            segmentedControl.setLabel(model.name, forSegment: i)
            segmentedControl.setWidth(0, forSegment: i) // auto-size
        }
        segmentedControl.selectedSegment = 0
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBg.cgColor

        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        addSubview(segmentedControl)

        // Bottom separator
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Theme.barBorder.cgColor
        addSubview(sep)

        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            segmentedControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func selectModel(named name: String) {
        if let idx = models.firstIndex(where: { $0.name == name }) {
            segmentedControl.selectedSegment = idx
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let model = selectedModel else { return }
        delegate?.tabBar(self, didSelectModel: model)
    }
}
