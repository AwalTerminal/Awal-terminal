#!/usr/bin/env swift
// generate-brand-assets.swift — Generates brand assets from Awal Terminal app icon
// Usage: swift scripts/generate-brand-assets.swift

import AppKit
import CoreGraphics
import CoreText

// --- Paths ---
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rootDir = scriptDir.deletingLastPathComponent()
let brandDir = rootDir.appendingPathComponent("brand")

// --- Shared Colors ---
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bgTop = CGColor(srgbRed: 0.102, green: 0.102, blue: 0.180, alpha: 1.0)
let bgBottom = CGColor(srgbRed: 0.059, green: 0.059, blue: 0.102, alpha: 1.0)
let strokeColor = CGColor(srgbRed: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)
let indigo = CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1.0)
let textColor = CGColor(srgbRed: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)
let subtitleColor = CGColor(srgbRed: 0.941, green: 0.941, blue: 0.961, alpha: 0.55)

// MARK: - Helpers

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Failed to create CGContext \(width)x\(height)") }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func savePNG(_ ctx: CGContext, to filename: String) {
    guard let image = ctx.makeImage() else { fatalError("Failed to create image") }
    let url = brandDir.appendingPathComponent(filename)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: ctx.width, height: ctx.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to create PNG data")
    }
    try! data.write(to: url)
    print("  \(filename) (\(ctx.width)x\(ctx.height))")
}

// MARK: - Drawing: Logomark (the "A" with crossbar)

func drawLogomark(_ ctx: CGContext, in rect: CGRect, withGlow: Bool = true) {
    let s = rect.width  // assume square bounding box
    let ox = rect.origin.x
    let oy = rect.origin.y

    let apexX = ox + s * 0.5
    let apexY = oy + s * 0.82
    let baseY = oy + s * 0.16
    let legSpread = s * 0.30
    let strokeW = s * (42.0 / 1024.0)

    let leftBaseX = apexX - legSpread
    let rightBaseX = apexX + legSpread

    // Ambient glow behind crossbar
    if withGlow {
        let crossbarY = oy + s * 0.40
        let glowGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.20),
                CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.08),
                CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.0),
            ] as CFArray, locations: [0.0, 0.5, 1.0]
        )!
        ctx.saveGState()
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: apexX, y: crossbarY), startRadius: 0,
            endCenter: CGPoint(x: apexX, y: crossbarY), endRadius: s * 0.38,
            options: []
        )
        ctx.restoreGState()
    }

    // Leg path
    let legPath = CGMutablePath()
    legPath.move(to: CGPoint(x: leftBaseX, y: baseY))
    legPath.addLine(to: CGPoint(x: apexX, y: apexY))
    legPath.addLine(to: CGPoint(x: rightBaseX, y: baseY))

    // Shadow pass
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.03,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
    ctx.setStrokeColor(strokeColor)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(20)
    ctx.addPath(legPath)
    ctx.strokePath()
    ctx.restoreGState()

    // Main stroke
    ctx.setStrokeColor(strokeColor)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(20)
    ctx.addPath(legPath)
    ctx.strokePath()

    // Crossbar
    if withGlow {
        drawCrossbar(ctx, s: s, ox: ox, oy: oy, apexX: apexX, apexY: apexY,
                     baseY: baseY, leftBaseX: leftBaseX, rightBaseX: rightBaseX, strokeW: strokeW)
    }
}

func drawCrossbar(_ ctx: CGContext, s: CGFloat, ox: CGFloat, oy: CGFloat,
                  apexX: CGFloat, apexY: CGFloat, baseY: CGFloat,
                  leftBaseX: CGFloat, rightBaseX: CGFloat, strokeW: CGFloat) {
    let crossbarY = oy + s * 0.40
    let crossbarH: CGFloat = s * (14.0 / 1024.0)
    let t = (crossbarY - baseY) / (apexY - baseY)
    let cLeft = leftBaseX + t * (apexX - leftBaseX) + strokeW * 0.55
    let cRight = rightBaseX + t * (apexX - rightBaseX) - strokeW * 0.55

    // Glow bar
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.025,
                  color: CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.8))
    let glowRect = CGRect(x: cLeft, y: crossbarY - crossbarH * 1.5,
                          width: cRight - cLeft, height: crossbarH * 3)
    let glowPath = CGPath(roundedRect: glowRect, cornerWidth: crossbarH * 1.5,
                          cornerHeight: crossbarH * 1.5, transform: nil)
    ctx.setFillColor(CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.25))
    ctx.addPath(glowPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Solid bar
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.012,
                  color: CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.9))
    let barRect = CGRect(x: cLeft, y: crossbarY - crossbarH / 2,
                         width: cRight - cLeft, height: crossbarH)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: crossbarH / 2,
                         cornerHeight: crossbarH / 2, transform: nil)
    ctx.setFillColor(indigo)
    ctx.addPath(barPath)
    ctx.fillPath()

    // Highlight center
    let hlRect = CGRect(x: cLeft + (cRight - cLeft) * 0.15, y: crossbarY - crossbarH * 0.3,
                        width: (cRight - cLeft) * 0.7, height: crossbarH * 0.6)
    let hlPath = CGPath(roundedRect: hlRect, cornerWidth: crossbarH * 0.3,
                        cornerHeight: crossbarH * 0.3, transform: nil)
    ctx.setFillColor(CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.5))
    ctx.addPath(hlPath)
    ctx.fillPath()
    ctx.restoreGState()
}

// Simplified "A" for small favicons — thicker strokes, no glow
func drawFavicon(_ ctx: CGContext, size: CGFloat) {
    let s = size
    let apexX = s * 0.5
    let apexY = s * 0.85
    let baseY = s * 0.12
    let legSpread = s * 0.34
    let strokeW = s * 0.12 // much thicker proportionally

    let leftBaseX = apexX - legSpread
    let rightBaseX = apexX + legSpread

    let legPath = CGMutablePath()
    legPath.move(to: CGPoint(x: leftBaseX, y: baseY))
    legPath.addLine(to: CGPoint(x: apexX, y: apexY))
    legPath.addLine(to: CGPoint(x: rightBaseX, y: baseY))

    ctx.setStrokeColor(strokeColor)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(20)
    ctx.addPath(legPath)
    ctx.strokePath()

    // Thick crossbar
    let crossbarY = s * 0.40
    let crossbarH = s * 0.08
    let t = (crossbarY - baseY) / (apexY - baseY)
    let cLeft = leftBaseX + t * (apexX - leftBaseX) + strokeW * 0.45
    let cRight = rightBaseX + t * (apexX - rightBaseX) - strokeW * 0.45

    let barRect = CGRect(x: cLeft, y: crossbarY - crossbarH / 2,
                         width: cRight - cLeft, height: crossbarH)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: crossbarH / 2,
                         cornerHeight: crossbarH / 2, transform: nil)
    ctx.setFillColor(indigo)
    ctx.addPath(barPath)
    ctx.fillPath()
}

// MARK: - Drawing: White logomark (no glow, pure white)

func drawLogomarkWhite(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width
    let ox = rect.origin.x
    let oy = rect.origin.y
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    let apexX = ox + s * 0.5
    let apexY = oy + s * 0.82
    let baseY = oy + s * 0.16
    let legSpread = s * 0.30
    let strokeW = s * (42.0 / 1024.0)

    let leftBaseX = apexX - legSpread
    let rightBaseX = apexX + legSpread

    let legPath = CGMutablePath()
    legPath.move(to: CGPoint(x: leftBaseX, y: baseY))
    legPath.addLine(to: CGPoint(x: apexX, y: apexY))
    legPath.addLine(to: CGPoint(x: rightBaseX, y: baseY))

    ctx.setStrokeColor(white)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(20)
    ctx.addPath(legPath)
    ctx.strokePath()

    // White crossbar (no glow)
    let crossbarY = oy + s * 0.40
    let crossbarH = s * (14.0 / 1024.0)
    let t = (crossbarY - baseY) / (apexY - baseY)
    let cLeft = leftBaseX + t * (apexX - leftBaseX) + strokeW * 0.55
    let cRight = rightBaseX + t * (apexX - rightBaseX) - strokeW * 0.55

    let barRect = CGRect(x: cLeft, y: crossbarY - crossbarH / 2,
                         width: cRight - cLeft, height: crossbarH)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: crossbarH / 2,
                         cornerHeight: crossbarH / 2, transform: nil)
    ctx.setFillColor(white)
    ctx.addPath(barPath)
    ctx.fillPath()
}

// MARK: - Drawing: Squircle icon (full app icon)

func drawSquircleIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size
    let cornerRadius = s * 0.224
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                              cornerHeight: cornerRadius, transform: nil)

    // Clip to squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Background gradient
    let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.125, green: 0.125, blue: 0.210, alpha: 1.0),
            bgTop, bgBottom,
        ] as CFArray, locations: [0.0, 0.4, 1.0]
    )!
    ctx.drawRadialGradient(
        bgGrad,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.65), startRadius: 0,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.72,
        options: [.drawsAfterEndLocation]
    )

    // Inner shadow
    ctx.saveGState()
    let bigRect = CGRect(x: -50, y: -50, width: s + 100, height: s + 100)
    let shadowPath = CGMutablePath()
    shadowPath.addRect(bigRect)
    shadowPath.addPath(squirclePath)
    ctx.addPath(shadowPath)
    ctx.clip(using: .evenOdd)
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 20,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
    ctx.addPath(squirclePath)
    ctx.fillPath()
    ctx.restoreGState()

    // Logomark
    drawLogomark(ctx, in: CGRect(x: 0, y: 0, width: s, height: s))

    // Top highlight
    let hlGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray, locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        hlGrad, start: CGPoint(x: s * 0.5, y: s),
        end: CGPoint(x: s * 0.5, y: s * 0.85), options: []
    )

    // Border
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(2.0)
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - Drawing: Dark background

func fillDarkBackground(_ ctx: CGContext, width: CGFloat, height: CGFloat) {
    let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.075, green: 0.075, blue: 0.130, alpha: 1.0),
            CGColor(srgbRed: 0.045, green: 0.045, blue: 0.080, alpha: 1.0),
        ] as CFArray, locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad, start: CGPoint(x: width * 0.5, y: height),
        end: CGPoint(x: width * 0.5, y: 0), options: [.drawsAfterEndLocation]
    )
}

// MARK: - Drawing: Wordmark text

func drawWordmark(_ ctx: CGContext, at origin: CGPoint, height: CGFloat, color: CGColor? = nil) {
    let fontSize = height * 0.65
    let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
    // Fall back if SF Pro not found — system font
    let actualFont: CTFont = CTFontCopyFullName(font) as String == "SF Pro Display" ? font
        : CTFontCreateUIFontForLanguage(.system, fontSize, nil)!

    let attrs: [NSAttributedString.Key: Any] = [
        .font: actualFont,
        .foregroundColor: color ?? textColor,
    ]
    let str = NSAttributedString(string: "Awal Terminal", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)

    ctx.saveGState()
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func drawTagline(_ ctx: CGContext, at origin: CGPoint, height: CGFloat) {
    let fontSize = height * 0.4
    let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
    let actualFont: CTFont = CTFontCopyFullName(font) as String == "SF Pro Display" ? font
        : CTFontCreateUIFontForLanguage(.system, fontSize, nil)!

    let attrs: [NSAttributedString.Key: Any] = [
        .font: actualFont,
        .foregroundColor: subtitleColor,
    ]
    let str = NSAttributedString(string: "Modern GPU-accelerated terminal", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)

    ctx.saveGState()
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func measureText(_ text: String, fontSize: CGFloat) -> CGSize {
    let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
    let actualFont: CTFont = CTFontCopyFullName(font) as String == "SF Pro Display" ? font
        : CTFontCreateUIFontForLanguage(.system, fontSize, nil)!

    let attrs: [NSAttributedString.Key: Any] = [.font: actualFont]
    let str = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    return CGSize(width: bounds.width, height: bounds.height)
}

// MARK: - Asset Generation

func generateLogomark() {
    let ctx = makeContext(1024, 1024)
    drawLogomark(ctx, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    savePNG(ctx, to: "logomark.png")
}

func generateLogomarkWhite() {
    let ctx = makeContext(1024, 1024)
    drawLogomarkWhite(ctx, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    savePNG(ctx, to: "logomark-white.png")
}

func generateProfileSquare() {
    let ctx = makeContext(800, 800)
    drawSquircleIcon(ctx, size: 800)
    savePNG(ctx, to: "profile-square.png")
}

func generateLinkedInBanner() {
    let w: CGFloat = 1584, h: CGFloat = 396
    let ctx = makeContext(Int(w), Int(h))
    fillDarkBackground(ctx, width: w, height: h)

    // Logomark on the left
    let iconSize: CGFloat = h * 0.6
    let iconY = (h - iconSize) / 2
    let iconX: CGFloat = h * 0.55
    drawLogomark(ctx, in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize))

    // Wordmark to the right
    let textX = iconX + iconSize + h * 0.2
    let textY = h * 0.42
    drawWordmark(ctx, at: CGPoint(x: textX, y: textY), height: h * 0.35)

    savePNG(ctx, to: "linkedin-banner.png")
}

func generateSocialCard() {
    let w: CGFloat = 1200, h: CGFloat = 630
    let ctx = makeContext(Int(w), Int(h))
    fillDarkBackground(ctx, width: w, height: h)

    // Centered logomark
    let iconSize: CGFloat = h * 0.42
    let iconX = (w - iconSize) / 2
    let iconY = h * 0.38
    drawLogomark(ctx, in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize))

    // Wordmark centered below
    let wmFontSize = h * 0.35 * 0.65
    let wmSize = measureText("Awal Terminal", fontSize: wmFontSize)
    let wmX = (w - wmSize.width) / 2
    let wmY = h * 0.22
    drawWordmark(ctx, at: CGPoint(x: wmX, y: wmY), height: h * 0.35)

    // Tagline centered below wordmark
    let tagFontSize = h * 0.25 * 0.4
    let tagSize = measureText("Modern GPU-accelerated terminal", fontSize: tagFontSize)
    let tagX = (w - tagSize.width) / 2
    let tagY = h * 0.10
    drawTagline(ctx, at: CGPoint(x: tagX, y: tagY), height: h * 0.25)

    savePNG(ctx, to: "social-card.png")
}

func generateBannerWide() {
    let w: CGFloat = 1920, h: CGFloat = 400
    let ctx = makeContext(Int(w), Int(h))
    fillDarkBackground(ctx, width: w, height: h)

    // Logomark left of center
    let iconSize: CGFloat = h * 0.55
    let totalWidth: CGFloat = iconSize + 30 + 500  // approx
    let startX = (w - totalWidth) / 2
    let iconY = (h - iconSize) / 2
    drawLogomark(ctx, in: CGRect(x: startX, y: iconY, width: iconSize, height: iconSize))

    // Wordmark right of logomark
    let textX = startX + iconSize + h * 0.15
    let textY = h * 0.43
    drawWordmark(ctx, at: CGPoint(x: textX, y: textY), height: h * 0.32)

    savePNG(ctx, to: "banner-wide.png")
}

func generateFavicons() {
    for size in [32, 16] {
        let s = CGFloat(size)
        let ctx = makeContext(size, size)
        // Dark background circle/square for visibility
        ctx.setFillColor(CGColor(srgbRed: 0.102, green: 0.102, blue: 0.180, alpha: 1.0))
        let r = s * 0.15
        let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(bg)
        ctx.fillPath()
        drawFavicon(ctx, size: s)
        savePNG(ctx, to: "favicon-\(size).png")
    }
}

// MARK: - Main

try FileManager.default.createDirectory(at: brandDir, withIntermediateDirectories: true)
print("Generating brand assets to brand/...")

generateLogomark()
generateLogomarkWhite()
generateProfileSquare()
generateLinkedInBanner()
generateSocialCard()
generateBannerWide()
generateFavicons()

print("Done! \(8) assets generated in brand/")
