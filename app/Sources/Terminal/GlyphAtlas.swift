import AppKit
import Metal
import CoreText
import CoreGraphics

struct GlyphKey: Hashable {
    let codepoint: UInt32
    let bold: Bool
    let italic: Bool
}

/// Key for multi-codepoint ligature glyphs.
struct LigatureKey: Hashable {
    let codepoints: [UInt32]
    let bold: Bool
    let italic: Bool
}

struct LigatureInfo {
    let glyphInfo: GlyphInfo
    let length: Int // number of cells the ligature spans
}

struct GlyphInfo {
    let uvRect: SIMD4<Float>    // x, y, w, h in normalized atlas coords
    let size: SIMD2<Float>      // glyph bitmap size in pixels (native resolution)
    let bearing: SIMD2<Float>   // offset from cell origin to glyph bitmap origin in pixels
}

final class GlyphAtlas {

    let texture: MTLTexture
    private let atlasWidth: Int = 4096
    private let atlasHeight: Int = 4096

    private var cache: [GlyphKey: GlyphInfo] = [:]
    private var ligatureCache: [LigatureKey: LigatureInfo] = [:]
    private(set) var ligaturesEnabled: Bool = false

    // Row-based packing state
    private var cursorX: Int = 0
    private var cursorY: Int = 0
    private var rowHeight: Int = 0
    private var needsReset = false


    private let font: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    private let symbolFont: CTFont?
    private let scale: CGFloat
    private let cellHeight: CGFloat

    init(device: MTLDevice, font: NSFont, boldFont: NSFont, cellHeight: CGFloat, scale: CGFloat) {
        self.font = font as CTFont
        self.boldFont = boldFont as CTFont
        self.scale = scale
        self.cellHeight = cellHeight

        // Create italic variants
        let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
        self.italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) as CTFont? ?? font as CTFont
        let boldItalicDesc = boldFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
        self.boldItalicFont = NSFont(descriptor: boldItalicDesc, size: boldFont.pointSize) as CTFont? ?? boldFont as CTFont

        // Find an installed Nerd Font for private use area glyphs
        self.symbolFont = GlyphAtlas.findNerdFont(size: font.pointSize)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Metal: failed to create glyph atlas texture")
        }
        self.texture = tex

        // Clear atlas to zero (transparent)
        let zeroBuffer = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        zeroBuffer.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: atlasWidth, height: atlasHeight, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: atlasWidth
            )
        }
    }

    /// Reset atlas state between frames if it filled up during the previous render.
    /// Called by MetalRenderer at the start of each render pass.
    func resetIfNeeded() {
        guard needsReset else { return }
        needsReset = false
        cursorX = 0
        cursorY = 0
        rowHeight = 0
        cache.removeAll(keepingCapacity: true)
        ligatureCache.removeAll(keepingCapacity: true)
    }

    func lookup(codepoint: UInt32, bold: Bool, italic: Bool = false, device: MTLDevice) -> GlyphInfo? {
        let key = GlyphKey(codepoint: codepoint, bold: bold, italic: italic)
        if let info = cache[key] {
            return info
        }
        return rasterize(key: key)
    }

    private func rasterize(key: GlyphKey) -> GlyphInfo? {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }

        let ctFont: CTFont
        if key.bold && key.italic {
            ctFont = boldItalicFont
        } else if key.bold {
            ctFont = boldFont
        } else if key.italic {
            ctFont = italicFont
        } else {
            ctFont = font
        }
        let ch = String(Character(scalar))
        let isPUA = (key.codepoint >= 0xE000 && key.codepoint <= 0xF8FF)
            || (key.codepoint >= 0xF0000 && key.codepoint <= 0xFFFFD)

        // Font fallback: primary -> symbol font -> system fallback (non-PUA only) -> skip
        let renderFont: CTFont
        if fontHasGlyph(ctFont, ch) {
            renderFont = ctFont
        } else if let sf = symbolFont, fontHasGlyph(sf, ch) {
            renderFont = sf
        } else if !isPUA {
            let systemFallback = CTFontCreateForString(ctFont, ch as CFString, CFRangeMake(0, ch.utf16.count))
            if fontHasGlyph(systemFallback, ch) {
                renderFont = systemFallback
            } else {
                return nil
            }
        } else {
            return nil // PUA glyph with no matching font — render nothing
        }
        let attrStr = NSAttributedString(string: ch, attributes: [
            .font: renderFont as NSFont,
            .foregroundColor: NSColor.white,
        ])
        let line = CTLineCreateWithAttributedString(attrStr)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // Bitmap dimensions in native pixels (scaled), with 1px padding
        let bitmapW = Int(ceil(width * scale)) + 2
        let bitmapH = Int(ceil((ascent + descent) * scale)) + 2
        guard bitmapW > 0, bitmapH > 0 else { return nil }

        // Row packing
        if cursorX + bitmapW > atlasWidth {
            cursorX = 0
            cursorY += rowHeight
            rowHeight = 0
        }
        if cursorY + bitmapH > atlasHeight {
            // Atlas full — defer reset to start of next frame
            needsReset = true
            return nil
        }

        // Rasterize at native pixel resolution
        // Use explicit BGRA byte order (macOS native) for reliable byte extraction
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: bitmapW,
            height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: 0, // let CG pick optimal stride
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: bitmapW, height: bitmapH))

        // Scale the context so CoreText renders at Retina resolution
        ctx.scaleBy(x: scale, y: scale)

        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)

        // Draw at baseline in points (context is scaled)
        let drawX: CGFloat = 1.0 / scale
        let drawY: CGFloat = 1.0 / scale + descent
        ctx.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }

        // BGRA byte order (byteOrder32Little + premultipliedFirst):
        // Memory layout: B, G, R, A per pixel
        // White text with coverage c: B=c, G=c, R=c, A=c
        // Use max of all channels for byte-order robustness
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let actualBytesPerRow = ctx.bytesPerRow
        let alphaData = UnsafeMutablePointer<UInt8>.allocate(capacity: bitmapW * bitmapH)
        for y in 0..<bitmapH {
            for x in 0..<bitmapW {
                let offset = y * actualBytesPerRow + x * 4
                let b0 = bytes[offset]
                let b1 = bytes[offset + 1]
                let b2 = bytes[offset + 2]
                let b3 = bytes[offset + 3]
                alphaData[y * bitmapW + x] = max(b0, max(b1, max(b2, b3)))
            }
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: cursorX, y: cursorY, z: 0),
            size: MTLSize(width: bitmapW, height: bitmapH, depth: 1)
        )
        texture.replace(region: region, mipmapLevel: 0, withBytes: alphaData, bytesPerRow: bitmapW)
        alphaData.deallocate()

        // UV rect in normalized atlas coordinates
        let uvX = Float(cursorX) / Float(atlasWidth)
        let uvY = Float(cursorY) / Float(atlasHeight)
        let uvW = Float(bitmapW) / Float(atlasWidth)
        let uvH = Float(bitmapH) / Float(atlasHeight)

        // Size and bearing in native pixels
        // The renderer passes these directly to the shader (no additional scaling needed)
        let fontAscent = CTFontGetAscent(font)
        let bearingX = Float(1.0) // 1 pixel padding
        // Center glyph bitmap vertically within the cell
        let cellHeightPx = cellHeight * scale
        let bearingY = Float((cellHeightPx - CGFloat(bitmapH)) / 2.0) + Float((fontAscent - ascent) * scale)

        let info = GlyphInfo(
            uvRect: SIMD4<Float>(uvX, uvY, uvW, uvH),
            size: SIMD2<Float>(Float(bitmapW), Float(bitmapH)),
            bearing: SIMD2<Float>(bearingX, bearingY)
        )

        cursorX += bitmapW
        rowHeight = max(rowHeight, bitmapH)

        cache[key] = info
        return info
    }

    var cachedCount: Int { cache.count }

    /// Search installed fonts for a Nerd Font (by name) that has Powerline glyphs.
    private static func findNerdFont(size: CGFloat) -> CTFont? {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return nil
        }

        let testChar: UniChar = 0xE0A0
        for fd in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(fd, kCTFontFamilyNameAttribute) as? String else { continue }
            guard name.contains("Nerd") || name.hasSuffix(" NF") || name.contains("Powerline") else { continue }
            let candidate = CTFontCreateWithFontDescriptor(fd, size, nil)
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(candidate, [testChar], &glyph, 1), glyph != 0 {
                NSLog("Found symbol font: \(CTFontCopyFullName(candidate))")
                return candidate
            }
        }
        return nil
    }

    private func fontHasGlyph(_ ctFont: CTFont, _ ch: String) -> Bool {
        let chars = Array(ch.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, chars.count) && glyphs[0] != 0
    }

    // MARK: - Ligature Support

    /// Enable ligature rendering. Call after init if the font supports ligatures.
    func enableLigatures() {
        // Check if the primary font has ligature tables by testing a common ligature
        let testStr = NSAttributedString(string: "->", attributes: [
            .font: font as NSFont,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 2,
        ])
        let line = CTLineCreateWithAttributedString(testStr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        // If CoreText merged 2 chars into fewer glyphs, the font supports ligatures
        var totalGlyphs = 0
        for run in runs { totalGlyphs += CTRunGetGlyphCount(run) }
        ligaturesEnabled = totalGlyphs < 2
    }

    /// Try to look up a ligature starting at the given position in a cell row.
    /// Returns (LigatureInfo, length) if a ligature was formed, nil otherwise.
    func lookupLigature(codepoints: UnsafeBufferPointer<UInt32>, startIndex: Int,
                        bold: Bool, italic: Bool, device: MTLDevice) -> LigatureInfo? {
        guard ligaturesEnabled else { return nil }

        // Try sequences of decreasing length (max 4 chars)
        let maxLen = min(4, codepoints.count - startIndex)
        guard maxLen >= 2 else { return nil }

        for len in stride(from: maxLen, through: 2, by: -1) {
            let seq = Array(codepoints[startIndex..<startIndex + len])

            // Skip if any codepoint is a space or control
            if seq.contains(where: { $0 <= 32 }) { continue }

            let key = LigatureKey(codepoints: seq, bold: bold, italic: italic)
            if let cached = ligatureCache[key] {
                return cached
            }

            // Try to rasterize this sequence as a ligature
            if let info = rasterizeLigature(key: key, length: len) {
                return info
            }
        }
        return nil
    }

    private func rasterizeLigature(key: LigatureKey, length: Int) -> LigatureInfo? {
        // Build the string from codepoints
        let str = String(key.codepoints.compactMap { Unicode.Scalar($0).map(Character.init) })
        guard str.count == length else { return nil }

        let ctFont: CTFont
        if key.bold && key.italic {
            ctFont = boldItalicFont
        } else if key.bold {
            ctFont = boldFont
        } else if key.italic {
            ctFont = italicFont
        } else {
            ctFont = font
        }

        // Create attributed string with ligatures enabled
        let attrStr = NSAttributedString(string: str, attributes: [
            .font: ctFont as NSFont,
            .foregroundColor: NSColor.white,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 2,
        ])
        let line = CTLineCreateWithAttributedString(attrStr)

        // Check if CoreText actually formed a ligature (fewer glyphs than chars)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var totalGlyphs = 0
        for run in runs { totalGlyphs += CTRunGetGlyphCount(run) }
        if totalGlyphs >= length {
            // No ligature formed — cache as nil
            ligatureCache[key] = nil
            return nil
        }

        // Rasterize the ligature glyph spanning multiple cells
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let bitmapW = Int(ceil(width * scale)) + 2
        let bitmapH = Int(ceil((ascent + descent) * scale)) + 2
        guard bitmapW > 0, bitmapH > 0 else { return nil }

        // Row packing
        if cursorX + bitmapW > atlasWidth {
            cursorX = 0
            cursorY += rowHeight
            rowHeight = 0
        }
        if cursorY + bitmapH > atlasHeight {
            needsReset = true
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil, width: bitmapW, height: bitmapH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: bitmapW, height: bitmapH))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)

        let drawX: CGFloat = 1.0 / scale
        let drawY: CGFloat = 1.0 / scale + descent
        ctx.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let actualBytesPerRow = ctx.bytesPerRow
        let alphaData = UnsafeMutablePointer<UInt8>.allocate(capacity: bitmapW * bitmapH)
        for y in 0..<bitmapH {
            for x in 0..<bitmapW {
                let offset = y * actualBytesPerRow + x * 4
                alphaData[y * bitmapW + x] = max(bytes[offset], max(bytes[offset+1], max(bytes[offset+2], bytes[offset+3])))
            }
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: cursorX, y: cursorY, z: 0),
            size: MTLSize(width: bitmapW, height: bitmapH, depth: 1)
        )
        texture.replace(region: region, mipmapLevel: 0, withBytes: alphaData, bytesPerRow: bitmapW)
        alphaData.deallocate()

        let uvX = Float(cursorX) / Float(atlasWidth)
        let uvY = Float(cursorY) / Float(atlasHeight)
        let uvW = Float(bitmapW) / Float(atlasWidth)
        let uvH = Float(bitmapH) / Float(atlasHeight)

        let fontAscent = CTFontGetAscent(font)
        let bearingX = Float(1.0)
        let cellHeightPx = cellHeight * scale
        let bearingY = Float((cellHeightPx - CGFloat(bitmapH)) / 2.0) + Float((fontAscent - ascent) * scale)

        let glyphInfo = GlyphInfo(
            uvRect: SIMD4<Float>(uvX, uvY, uvW, uvH),
            size: SIMD2<Float>(Float(bitmapW), Float(bitmapH)),
            bearing: SIMD2<Float>(bearingX, bearingY)
        )

        cursorX += bitmapW
        rowHeight = max(rowHeight, bitmapH)

        let info = LigatureInfo(glyphInfo: glyphInfo, length: length)
        ligatureCache[key] = info
        return info
    }
}
