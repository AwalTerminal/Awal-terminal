import AppKit
import Metal
import CoreText
import CoreGraphics

struct GlyphKey: Hashable {
    let codepoint: UInt32
    let bold: Bool
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
    private let scale: CGFloat

    init(device: MTLDevice, font: NSFont, boldFont: NSFont, scale: CGFloat) {
        self.font = font as CTFont
        self.boldFont = boldFont as CTFont
        self.scale = scale

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

    func lookup(codepoint: UInt32, bold: Bool, device: MTLDevice) -> GlyphInfo? {
        let key = GlyphKey(codepoint: codepoint, bold: bold)
        if let info = cache[key] {
            return info
        }
        return rasterize(key: key)
    }

    private func rasterize(key: GlyphKey) -> GlyphInfo? {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }

        let ctFont = key.bold ? boldFont : font
        let ch = String(Character(scalar))
        let attrStr = NSAttributedString(string: ch, attributes: [
            .font: ctFont as NSFont
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
}
