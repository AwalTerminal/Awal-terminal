#!/usr/bin/env swift
// generate-icon.swift — Generates Awal Terminal app icon (geometric "A" letterform)
// Usage: swift scripts/generate-icon.swift

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rootDir = scriptDir.deletingLastPathComponent()
let outputPNG = rootDir.appendingPathComponent("app/Sources/App/Resources/AppIcon-source.png")
let generateIconSh = scriptDir.appendingPathComponent("generate-icon.sh")

// --- Colors ---
let bgTop = CGColor(srgbRed: 0.102, green: 0.102, blue: 0.180, alpha: 1.0)     // #1a1a2e
let bgBottom = CGColor(srgbRed: 0.059, green: 0.059, blue: 0.102, alpha: 1.0)   // #0f0f1a
let strokeColor = CGColor(srgbRed: 0.941, green: 0.941, blue: 0.961, alpha: 1.0) // #f0f0f5
let indigo = CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1.0)     // #6366f1
let indigoGlow = CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 1.0) // #818cf8

// --- Create bitmap context ---
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: Int(size) * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)

// --- Squircle path (continuous corners) ---
let inset: CGFloat = 0
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius = size * 0.224  // ~22.4% per Apple guidelines
let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Clip to squircle
ctx.addPath(squirclePath)
ctx.clip()

// --- Background gradient (radial, lighter at center-top) ---
let bgGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.125, green: 0.125, blue: 0.210, alpha: 1.0), // slightly lighter center
        bgTop,
        bgBottom
    ] as CFArray,
    locations: [0.0, 0.4, 1.0]
)!
ctx.drawRadialGradient(
    bgGradient,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.65),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.5),
    endRadius: size * 0.72,
    options: [.drawsAfterEndLocation]
)

// --- Inner shadow (subtle depth at edges) ---
ctx.saveGState()
let bigRect = CGRect(x: -50, y: -50, width: size + 100, height: size + 100)
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

// --- Indigo ambient glow behind crossbar area ---
let crossbarY = size * 0.40  // crossbar vertical position (from bottom in CG coords)
let glowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.20),
        CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.08),
        CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!
ctx.drawRadialGradient(
    glowGradient,
    startCenter: CGPoint(x: size * 0.5, y: crossbarY),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: crossbarY),
    endRadius: size * 0.38,
    options: []
)

// --- Geometry for "A" letterform ---
// The "A" is drawn in CoreGraphics coordinates (origin bottom-left)
let apexX = size * 0.5
let apexY = size * 0.82    // top of the A
let baseY = size * 0.16    // bottom of legs
let legSpread = size * 0.30 // half-width at base
let strokeWidth: CGFloat = 42

// Left leg: bottom-left to apex
let leftBaseX = apexX - legSpread
// Right leg: apex to bottom-right
let rightBaseX = apexX + legSpread

// --- Draw "A" legs as a stroked path with miter join at apex ---
ctx.saveGState()

let legPath = CGMutablePath()
legPath.move(to: CGPoint(x: leftBaseX, y: baseY))
legPath.addLine(to: CGPoint(x: apexX, y: apexY))
legPath.addLine(to: CGPoint(x: rightBaseX, y: baseY))

// Shadow pass
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
ctx.setStrokeColor(strokeColor)
ctx.setLineWidth(strokeWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.miter)
ctx.setMiterLimit(20)
ctx.addPath(legPath)
ctx.strokePath()
ctx.restoreGState()

// Main stroke
ctx.setStrokeColor(strokeColor)
ctx.setLineWidth(strokeWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.miter)
ctx.setMiterLimit(20)
ctx.addPath(legPath)
ctx.strokePath()

ctx.restoreGState()

// --- Crossbar (indigo accent) ---
let crossbarHeight: CGFloat = 14
// Calculate crossbar endpoints on the inner edges of the legs at crossbarY
let t = (crossbarY - baseY) / (apexY - baseY) // parametric position along leg
let crossbarLeftX = leftBaseX + t * (apexX - leftBaseX) + strokeWidth * 0.55
let crossbarRightX = rightBaseX + t * (apexX - rightBaseX) - strokeWidth * 0.55

// Crossbar glow (drawn first, behind)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 25,
              color: CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.8))

let glowBarRect = CGRect(
    x: crossbarLeftX,
    y: crossbarY - crossbarHeight * 1.5,
    width: crossbarRightX - crossbarLeftX,
    height: crossbarHeight * 3
)
let glowBarPath = CGPath(roundedRect: glowBarRect, cornerWidth: crossbarHeight * 1.5, cornerHeight: crossbarHeight * 1.5, transform: nil)
ctx.setFillColor(CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 0.25))
ctx.addPath(glowBarPath)
ctx.fillPath()
ctx.restoreGState()

// Crossbar solid bar
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 12,
              color: CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.9))

let barRect = CGRect(
    x: crossbarLeftX,
    y: crossbarY - crossbarHeight / 2,
    width: crossbarRightX - crossbarLeftX,
    height: crossbarHeight
)
let barPath = CGPath(roundedRect: barRect, cornerWidth: crossbarHeight / 2, cornerHeight: crossbarHeight / 2, transform: nil)
ctx.setFillColor(indigo)
ctx.addPath(barPath)
ctx.fillPath()

// Brighter center highlight on crossbar
let highlightRect = CGRect(
    x: crossbarLeftX + (crossbarRightX - crossbarLeftX) * 0.15,
    y: crossbarY - crossbarHeight * 0.3,
    width: (crossbarRightX - crossbarLeftX) * 0.7,
    height: crossbarHeight * 0.6
)
let highlightPath = CGPath(roundedRect: highlightRect, cornerWidth: crossbarHeight * 0.3, cornerHeight: crossbarHeight * 0.3, transform: nil)
ctx.setFillColor(CGColor(srgbRed: 0.506, green: 0.549, blue: 0.973, alpha: 0.5))
ctx.addPath(highlightPath)
ctx.fillPath()
ctx.restoreGState()

// --- Top highlight (faint reflection at top edge) ---
ctx.saveGState()
let highlightGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    highlightGradient,
    start: CGPoint(x: size * 0.5, y: size),
    end: CGPoint(x: size * 0.5, y: size * 0.85),
    options: []
)
ctx.restoreGState()

// --- Squircle border stroke ---
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
ctx.setLineWidth(2.0)
ctx.strokePath()
ctx.restoreGState()

// --- Export to PNG ---
guard let image = ctx.makeImage() else {
    fatalError("Failed to create image from context")
}
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to create PNG data")
}

// Ensure output directory exists
let outputDir = outputPNG.deletingLastPathComponent()
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

try pngData.write(to: outputPNG)
print("Generated \(outputPNG.path)")

// --- Chain to generate-icon.sh to produce .icns ---
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [generateIconSh.path]
process.currentDirectoryURL = rootDir
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Icon generation complete!")
} else {
    print("Warning: generate-icon.sh exited with status \(process.terminationStatus)")
}
