import AppKit

/// Real-time audio level waveform visualization using CoreGraphics.
class WaveformView: NSView {

    /// Number of bars to display
    var barCount: Int = 7

    /// Base bar color (low level)
    var barColor: NSColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)

    /// Bright bar color (high level)
    var barColorBright: NSColor = NSColor(red: 80.0/255.0, green: 255.0/255.0, blue: 140.0/255.0, alpha: 1.0)

    /// Smoothing factor for exponential smoothing (0 = no smoothing, 1 = frozen)
    private let smoothingFactor: Float = 0.3

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
            let level = CGFloat(levels[i])
            let height = max(2, level * maxHeight)
            let x = CGFloat(i * 2) * barWidth
            let y = (bounds.height - height) / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)

            // Interpolate color based on level
            let color = NSColor.interpolate(from: barColor, to: barColorBright, fraction: level)
            ctx.setFillColor(color.cgColor)
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
        let rawLevel = min(1.0, audioLevel * variation * 3.0)

        // Exponential smoothing for smoother transitions
        let previous = levels[barCount - 1]
        levels[barCount - 1] = previous * smoothingFactor + rawLevel * (1.0 - smoothingFactor)

        needsDisplay = true
    }
}

// MARK: - NSColor interpolation

private extension NSColor {
    static func interpolate(from: NSColor, to: NSColor, fraction: CGFloat) -> NSColor {
        let f = min(max(fraction, 0), 1)
        let fromRGB = from.usingColorSpace(.sRGB) ?? from
        let toRGB = to.usingColorSpace(.sRGB) ?? to
        return NSColor(
            red: fromRGB.redComponent + (toRGB.redComponent - fromRGB.redComponent) * f,
            green: fromRGB.greenComponent + (toRGB.greenComponent - fromRGB.greenComponent) * f,
            blue: fromRGB.blueComponent + (toRGB.blueComponent - fromRGB.blueComponent) * f,
            alpha: fromRGB.alphaComponent + (toRGB.alphaComponent - fromRGB.alphaComponent) * f
        )
    }
}
