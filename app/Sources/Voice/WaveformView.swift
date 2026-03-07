import AppKit

/// Real-time audio level waveform visualization using CoreGraphics.
class WaveformView: NSView {

    /// Number of bars to display
    var barCount: Int = 5

    /// Bar color
    var barColor: NSColor = NSColor(red: 120/255, green: 220/255, blue: 120/255, alpha: 1.0)

    /// Current audio level (0.0 - 1.0)
    var audioLevel: Float = 0 {
        didSet { needsDisplay = true }
    }

    /// Historical levels for animation
    private var levels: [Float] = []
    private var updateTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        levels = [Float](repeating: 0, count: barCount)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func startAnimating() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.updateLevels()
        }
    }

    func stopAnimating() {
        updateTimer?.invalidate()
        updateTimer = nil
        levels = [Float](repeating: 0, count: barCount)
        needsDisplay = true
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let barWidth = bounds.width / CGFloat(barCount * 2 - 1)
        let maxHeight = bounds.height - 2

        for i in 0..<min(barCount, levels.count) {
            let height = max(2, CGFloat(levels[i]) * maxHeight)
            let x = CGFloat(i * 2) * barWidth
            let y = (bounds.height - height) / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)

            ctx.setFillColor(barColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // MARK: - Private

    private func updateLevels() {
        // Shift levels and add new one with some variation
        for i in 0..<(barCount - 1) {
            levels[i] = levels[i + 1]
        }

        // Add variation to make it look natural
        let variation = Float.random(in: 0.7...1.3)
        levels[barCount - 1] = min(1.0, audioLevel * variation * 3.0)

        needsDisplay = true
    }
}
