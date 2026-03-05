import AppKit
import Metal
import CoreText
import CoreGraphics

struct GlyphKey: Hashable {
    let codepoint: UInt32
    let bold: Bool
    let italic: Bool
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

    // Row-based packing state
    private var cursorX: Int = 0
    private var cursorY: Int = 0
    private var rowHeight: Int = 0

    private let font: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    private let symbolFont: CTFont?
    private let scale: CGFloat

    init(device: MTLDevice, font: NSFont, boldFont: NSFont, scale: CGFloat) {
        self.font = font as CTFont
        self.boldFont = boldFont as CTFont
        self.scale = scale

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
        self.texture = device.makeTexture(descriptor: desc)!

        // Clear atlas to zero (transparent)
        let zeroData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        zeroData.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: atlasWidth, height: atlasHeight, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: atlasWidth
            )
        }
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
            .font: renderFont as NSFont
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
            return nil
        }

        // Rasterize at native pixel resolution
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: bitmapW,
            height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: bitmapW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: bitmapW, height: bitmapH))

        // Scale the context so CoreText renders at Retina resolution
        ctx.scaleBy(x: scale, y: scale)

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)

        // Draw at baseline in points (context is scaled)
        let drawX: CGFloat = 1.0 / scale
        let drawY: CGFloat = 1.0 / scale + descent
        ctx.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }

        // Extract alpha channel
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let alphaData = UnsafeMutablePointer<UInt8>.allocate(capacity: bitmapW * bitmapH)
        for i in 0..<(bitmapW * bitmapH) {
            alphaData[i] = rgba[i * 4 + 3]
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
        let bearingY = Float((fontAscent - ascent) * scale) + 1.0

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
}
