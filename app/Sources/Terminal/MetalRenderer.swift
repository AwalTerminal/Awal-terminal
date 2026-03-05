import Metal
import QuartzCore
import AppKit
import CAwalTerminal

// MARK: - GPU-side structs (must match cell.metal packed_ types)
// Using plain Float/UInt32 fields to avoid SIMD alignment padding.
// Metal packed_float2/packed_float4 have 1-byte alignment, so no padding.
// Swift SIMD2<Float> has 8-byte alignment and SIMD4<Float> has 16-byte alignment,
// which would insert padding and break the layout.

struct Uniforms {
    // Metal float2/uint2 (non-packed) — 8-byte aligned, matches SIMD
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var gridSize: SIMD2<UInt32>
}

struct BgInstance {
    // Must match: packed_float2 position (8 bytes) + packed_uchar4 color (4 bytes) = 12 bytes
    var posX: Float
    var posY: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

struct GlyphInstance {
    // Must match: packed_float2 (8) + packed_float4 (16) + packed_float2 (8) + packed_float2 (8) + packed_uchar4 (4) = 44 bytes
    var posX: Float
    var posY: Float
    var uvX: Float
    var uvY: Float
    var uvW: Float
    var uvH: Float
    var sizeW: Float
    var sizeH: Float
    var bearX: Float
    var bearY: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

struct LineInstance {
    // packed_float4 rect (x, y, w, h in pixels) + packed_uchar4 color = 20 bytes
    var x: Float
    var y: Float
    var w: Float
    var h: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

final class MetalRenderer {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    let atlas: GlyphAtlas

    // Triple buffering
    private let maxInflightFrames = 3
    private let frameSemaphore: DispatchSemaphore

    // Instance buffers (grown as needed)
    private var bgBuffer: MTLBuffer?
    private var bgBufferCapacity: Int = 0
    private var glyphBuffer: MTLBuffer?
    private var glyphBufferCapacity: Int = 0
    private var lineBuffer: MTLBuffer?
    private var lineBufferCapacity: Int = 0
    private var uniformBuffer: MTLBuffer

    private let cellWidth: CGFloat
    private let cellHeight: CGFloat

    // Theme colors
    let clearColor: MTLClearColor
    let cursorColor: (UInt8, UInt8, UInt8, UInt8)

    // Shader source embedded inline for reliable runtime compilation
    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
        float2 cellSize;
        uint2  gridSize;
    };

    // --- Cell Backgrounds ---

    struct BgInstance {
        packed_float2 position;
        packed_uchar4 color;
    };

    struct BgVertexOut {
        float4 position [[position]];
        float4 color;
    };

    vertex BgVertexOut bg_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device BgInstance* instances [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        float2 corners[] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(0, 1), float2(1, 0), float2(1, 1)
        };
        float2 corner = corners[vertexID];
        BgInstance inst = instances[instanceID];
        float2 gridPos = float2(inst.position[0], inst.position[1]);
        float2 pixelPos = (gridPos + corner) * uniforms.cellSize;
        float2 ndc;
        ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;
        BgVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = float4(
            float(inst.color[0]) / 255.0,
            float(inst.color[1]) / 255.0,
            float(inst.color[2]) / 255.0,
            float(inst.color[3]) / 255.0
        );
        return out;
    }

    fragment float4 bg_fragment(BgVertexOut in [[stage_in]]) {
        return in.color;
    }

    // --- Glyph Rendering ---

    struct GlyphInstance {
        packed_float2 position;
        packed_float4 uvRect;
        packed_float2 glyphSize;
        packed_float2 bearing;
        packed_uchar4 color;
    };

    struct GlyphVertexOut {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
    };

    vertex GlyphVertexOut glyph_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device GlyphInstance* instances [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        float2 corners[] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(0, 1), float2(1, 0), float2(1, 1)
        };
        float2 corner = corners[vertexID];
        GlyphInstance inst = instances[instanceID];
        float2 gridPos = float2(inst.position[0], inst.position[1]);
        float4 uvRect = float4(inst.uvRect[0], inst.uvRect[1], inst.uvRect[2], inst.uvRect[3]);
        float2 glyphSize = float2(inst.glyphSize[0], inst.glyphSize[1]);
        float2 bearing = float2(inst.bearing[0], inst.bearing[1]);
        float2 cellOrigin = gridPos * uniforms.cellSize;
        float2 glyphOrigin = cellOrigin + bearing;
        float2 pixelPos = glyphOrigin + corner * glyphSize;
        float2 ndc;
        ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;
        float2 texCoord = uvRect.xy + corner * uvRect.zw;
        GlyphVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = texCoord;
        out.color = float4(
            float(inst.color[0]) / 255.0,
            float(inst.color[1]) / 255.0,
            float(inst.color[2]) / 255.0,
            float(inst.color[3]) / 255.0
        );
        return out;
    }

    fragment float4 glyph_fragment(
        GlyphVertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float alpha = atlas.sample(s, in.texCoord).r;
        return float4(in.color.rgb, in.color.a * alpha);
    }

    // --- Line decorations (underline, strikethrough) ---

    struct LineInstance {
        packed_float4 rect;  // x, y, w, h in pixels
        packed_uchar4 color;
    };

    struct LineVertexOut {
        float4 position [[position]];
        float4 color;
    };

    vertex LineVertexOut line_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device LineInstance* instances [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        float2 corners[] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(0, 1), float2(1, 0), float2(1, 1)
        };
        float2 corner = corners[vertexID];
        LineInstance inst = instances[instanceID];
        float4 rect = float4(inst.rect[0], inst.rect[1], inst.rect[2], inst.rect[3]);
        float2 pixelPos = float2(rect.x + corner.x * rect.z, rect.y + corner.y * rect.w);
        float2 ndc;
        ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;
        LineVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = float4(
            float(inst.color[0]) / 255.0,
            float(inst.color[1]) / 255.0,
            float(inst.color[2]) / 255.0,
            float(inst.color[3]) / 255.0
        );
        return out;
    }

    fragment float4 line_fragment(LineVertexOut in [[stage_in]]) {
        return in.color;
    }
    """

    deinit {
        // Wait for all in-flight frames to complete before the semaphore is deallocated
        for _ in 0..<maxInflightFrames {
            frameSemaphore.wait()
        }
        for _ in 0..<maxInflightFrames {
            frameSemaphore.signal()
        }
    }

    init(device: MTLDevice, font: NSFont, boldFont: NSFont, cellWidth: CGFloat, cellHeight: CGFloat, scale: CGFloat, bgColor: NSColor? = nil, cursorColor cursorNSColor: NSColor? = nil) {
        self.device = device
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight

        // Theme colors — convert to sRGB to safely access r/g/b components
        let bg = (bgColor ?? AppConfig.shared.themeBg).usingColorSpace(.sRGB)
            ?? NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        self.clearColor = MTLClearColor(
            red: Double(bg.redComponent),
            green: Double(bg.greenComponent),
            blue: Double(bg.blueComponent),
            alpha: 1.0
        )
        let cc = (cursorNSColor ?? AppConfig.shared.themeCursor).usingColorSpace(.sRGB)
            ?? NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 0.7)
        self.cursorColor = (
            UInt8(cc.redComponent * 255),
            UInt8(cc.greenComponent * 255),
            UInt8(cc.blueComponent * 255),
            UInt8(cc.alphaComponent * 255)
        )
        self.commandQueue = device.makeCommandQueue()!
        self.frameSemaphore = DispatchSemaphore(value: maxInflightFrames)

        // Compile shaders at runtime
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
        } catch {
            fatalError("Failed to compile Metal shaders: \(error)")
        }

        // Background pipeline (opaque + alpha blend for cursor)
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "bg_vertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "bg_fragment")
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        bgDesc.colorAttachments[0].isBlendingEnabled = true
        bgDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bgDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bgDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        bgDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
        } catch {
            fatalError("Failed to create bg pipeline: \(error)")
        }

        // Glyph pipeline (alpha-blended)
        let glyphDesc = MTLRenderPipelineDescriptor()
        glyphDesc.vertexFunction = library.makeFunction(name: "glyph_vertex")
        glyphDesc.fragmentFunction = library.makeFunction(name: "glyph_fragment")
        glyphDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        glyphDesc.colorAttachments[0].isBlendingEnabled = true
        glyphDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        glyphDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        glyphDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        glyphDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            glyphPipeline = try device.makeRenderPipelineState(descriptor: glyphDesc)
        } catch {
            fatalError("Failed to create glyph pipeline: \(error)")
        }

        // Line decoration pipeline (alpha-blended)
        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.vertexFunction = library.makeFunction(name: "line_vertex")
        lineDesc.fragmentFunction = library.makeFunction(name: "line_fragment")
        lineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        lineDesc.colorAttachments[0].isBlendingEnabled = true
        lineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        lineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        lineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            linePipeline = try device.makeRenderPipelineState(descriptor: lineDesc)
        } catch {
            fatalError("Failed to create line pipeline: \(error)")
        }

        // Atlas — rasterize glyphs at native pixel resolution
        self.atlas = GlyphAtlas(device: device, font: font, boldFont: boldFont, cellHeight: cellHeight, scale: scale)

        // Uniform buffer
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.size,
                                                options: .storageModeShared)!
    }

    /// Render a frame. Call from display link callback.
    func render(
        cells: UnsafePointer<CCell>,
        cellCount: Int,
        gridCols: Int,
        gridRows: Int,
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        cursorBlinkOn: Bool,
        drawable: CAMetalDrawable,
        viewportSize: CGSize,
        scale: CGFloat,
        searchHighlights: [(col: Int, row: Int, len: Int)] = [],
        currentHighlight: Int = -1
    ) {
        // Non-blocking wait to avoid freezing the main thread
        let result = frameSemaphore.wait(timeout: .now() + .milliseconds(16))
        if result == .timedOut {
            return
        }

        // cellSize is in points; viewport is in pixels. Scale cellSize to match.
        let scaledCellW = Float(cellWidth * scale)
        let scaledCellH = Float(cellHeight * scale)

        // Update uniforms
        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height)),
            cellSize: SIMD2<Float>(scaledCellW, scaledCellH),
            gridSize: SIMD2<UInt32>(UInt32(gridCols), UInt32(gridRows))
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)

        // Build instance data
        let totalCells = gridCols * gridRows
        guard cellCount >= totalCells else {
            frameSemaphore.signal()
            return
        }

        // Pre-allocate instance arrays
        var bgInstances: [BgInstance] = []
        bgInstances.reserveCapacity(totalCells)
        var glyphInstances: [GlyphInstance] = []
        glyphInstances.reserveCapacity(totalCells)
        var lineInstances: [LineInstance] = []

        // Hoist clear color comparison values out of the inner loop
        let clearR = UInt8(clearColor.red * 255)
        let clearG = UInt8(clearColor.green * 255)
        let clearB = UInt8(clearColor.blue * 255)

        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let idx = row * gridCols + col
                let cell = cells[idx]

                let isWideSpacer = (cell.attrs & 0x0200) != 0
                if cell.bg_r != clearR || cell.bg_g != clearG || cell.bg_b != clearB {
                    bgInstances.append(BgInstance(
                        posX: Float(col), posY: Float(row),
                        r: cell.bg_r, g: cell.bg_g, b: cell.bg_b, a: cell.bg_a
                    ))
                }

                // Underline decoration (attr bit 3 = 0x08)
                let hasUnderline = (cell.attrs & 0x08) != 0
                if hasUnderline {
                    let lineY = Float(row + 1) * scaledCellH - 1.0 * Float(scale)
                    lineInstances.append(LineInstance(
                        x: Float(col) * scaledCellW,
                        y: lineY,
                        w: scaledCellW,
                        h: max(1.0, Float(scale)),
                        r: cell.fg_r, g: cell.fg_g, b: cell.fg_b, a: cell.fg_a
                    ))
                }

                // Strikethrough decoration (attr bit 7 = 0x80)
                let hasStrikethrough = (cell.attrs & 0x80) != 0
                if hasStrikethrough {
                    let lineY = (Float(row) + 0.5) * scaledCellH
                    lineInstances.append(LineInstance(
                        x: Float(col) * scaledCellW,
                        y: lineY,
                        w: scaledCellW,
                        h: max(1.0, Float(scale)),
                        r: cell.fg_r, g: cell.fg_g, b: cell.fg_b, a: cell.fg_a
                    ))
                }

                // Glyph: skip spaces, control chars, and wide spacers
                if isWideSpacer { continue }
                let codepoint = cell.codepoint
                guard codepoint > 32 else { continue }

                let isBold = (cell.attrs & 0x01) != 0
                let isItalic = (cell.attrs & 0x04) != 0
                guard let info = atlas.lookup(codepoint: codepoint, bold: isBold, italic: isItalic, device: device) else {
                    continue
                }

                // Atlas size/bearing are already in native pixels
                glyphInstances.append(GlyphInstance(
                    posX: Float(col), posY: Float(row),
                    uvX: info.uvRect.x, uvY: info.uvRect.y,
                    uvW: info.uvRect.z, uvH: info.uvRect.w,
                    sizeW: info.size.x, sizeH: info.size.y,
                    bearX: info.bearing.x, bearY: info.bearing.y,
                    r: cell.fg_r, g: cell.fg_g, b: cell.fg_b, a: cell.fg_a
                ))
            }
        }

        // Search highlight instances
        for (i, hl) in searchHighlights.enumerated() {
            let isCurrent = (i == currentHighlight)
            let hlR: UInt8 = isCurrent ? 255 : 180
            let hlG: UInt8 = isCurrent ? 200 : 140
            let hlB: UInt8 = isCurrent ? 50 : 30
            let hlA: UInt8 = isCurrent ? 180 : 100
            for c in 0..<hl.len {
                bgInstances.append(BgInstance(
                    posX: Float(hl.col + c), posY: Float(hl.row),
                    r: hlR, g: hlG, b: hlB, a: hlA
                ))
            }
        }

        // Cursor instance
        if cursorVisible && cursorBlinkOn {
            bgInstances.append(BgInstance(
                posX: Float(cursorCol), posY: Float(cursorRow),
                r: cursorColor.0, g: cursorColor.1, b: cursorColor.2, a: cursorColor.3
            ))
        }

        // Ensure GPU buffers are large enough
        ensureBgBuffer(count: bgInstances.count)
        ensureGlyphBuffer(count: glyphInstances.count)
        ensureLineBuffer(count: lineInstances.count)

        // Copy instance data to GPU buffers
        if !bgInstances.isEmpty, let buf = bgBuffer {
            _ = bgInstances.withUnsafeBytes { ptr in
                memcpy(buf.contents(), ptr.baseAddress!, ptr.count)
            }
        }
        if !glyphInstances.isEmpty, let buf = glyphBuffer {
            _ = glyphInstances.withUnsafeBytes { ptr in
                memcpy(buf.contents(), ptr.baseAddress!, ptr.count)
            }
        }
        if !lineInstances.isEmpty, let buf = lineBuffer {
            _ = lineInstances.withUnsafeBytes { ptr in
                memcpy(buf.contents(), ptr.baseAddress!, ptr.count)
            }
        }

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }

        // Render pass
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = clearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            frameSemaphore.signal()
            return
        }

        // Draw backgrounds (including cursor)
        if !bgInstances.isEmpty, let buf = bgBuffer {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: bgInstances.count)
        }

        // Draw glyphs
        if !glyphInstances.isEmpty, let buf = glyphBuffer {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: glyphInstances.count)
        }

        // Draw line decorations (underline, strikethrough)
        if !lineInstances.isEmpty, let buf = lineBuffer {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: lineInstances.count)
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
        }
        commandBuffer.commit()
    }

    // MARK: - Buffer Management

    private func ensureBgBuffer(count: Int) {
        guard count > 0 else { return }
        let needed = count * MemoryLayout<BgInstance>.stride
        if bgBufferCapacity < needed {
            let newCap = max(needed, bgBufferCapacity * 2, 4096)
            bgBuffer = device.makeBuffer(length: newCap, options: .storageModeShared)
            bgBufferCapacity = newCap
        }
    }

    private func ensureGlyphBuffer(count: Int) {
        guard count > 0 else { return }
        let needed = count * MemoryLayout<GlyphInstance>.stride
        if glyphBufferCapacity < needed {
            let newCap = max(needed, glyphBufferCapacity * 2, 4096)
            glyphBuffer = device.makeBuffer(length: newCap, options: .storageModeShared)
            glyphBufferCapacity = newCap
        }
    }

    private func ensureLineBuffer(count: Int) {
        guard count > 0 else { return }
        let needed = count * MemoryLayout<LineInstance>.stride
        if lineBufferCapacity < needed {
            let newCap = max(needed, lineBufferCapacity * 2, 4096)
            lineBuffer = device.makeBuffer(length: newCap, options: .storageModeShared)
            lineBufferCapacity = newCap
        }
    }
}
