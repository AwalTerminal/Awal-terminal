import AppKit
import CAwalTerminal

// MARK: - Zoom

extension TerminalView {

    var currentFontSize: CGFloat { font.pointSize }

    func zoomIn() {
        applyFontSize(font.pointSize + zoomStep)
    }

    func zoomOut() {
        applyFontSize(font.pointSize - zoomStep)
    }

    func resetZoom() {
        applyFontSize(baseFontSize)
    }

    func applyFontSize(_ size: CGFloat) {
        let clamped = min(max(size, minFontSize), maxFontSize)
        guard clamped != font.pointSize else { return }

        // Resolve fonts at the new size
        let config = AppConfig.shared
        let family = config.fontFamily.isEmpty ? BundledFont.defaultFontFamily : config.fontFamily
        let newFont: NSFont
        if let f = NSFont(name: family, size: clamped) {
            newFont = f
        } else if let f = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: clamped) {
            newFont = f
        } else {
            newFont = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        }

        let newBoldFont: NSFont
        if let f = NSFont(name: "\(family)-Bold", size: clamped) {
            newBoldFont = f
        } else {
            let boldDesc = newFont.fontDescriptor.withSymbolicTraits(.bold)
            newBoldFont = NSFont(descriptor: boldDesc, size: clamped) ?? NSFont.monospacedSystemFont(ofSize: clamped, weight: .bold)
        }

        self.font = newFont
        self.boldFont = newBoldFont

        // Recalculate cell metrics
        let ctFont = newFont as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        let mChar: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(ctFont, [mChar], &glyph, 1)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, [glyph], &advance, 1)
        self.cellWidth = ceil(advance.width)
        self.cellHeight = ceil(ascent + descent + leading)
        self.baselineOffset = descent

        // Recreate renderer with new font metrics (same pattern as updateBackingScale)
        if let device = metalLayer?.device {
            stopDisplayLink()
            do {
                renderer = try MetalRenderer(
                    device: device,
                    font: font,
                    boldFont: boldFont,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    scale: currentScale
                )
            } catch {
                debugLog("MetalRenderer reinit for zoom failed: \(error.localizedDescription)")
            }
            startDisplayLink()
        }

        recalculateGridSize()
        showZoomHUD()
    }

    override func magnify(with event: NSEvent) {
        let delta = event.magnification * 4.0
        applyFontSize(font.pointSize + delta)
    }
}
