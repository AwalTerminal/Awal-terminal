import AppKit
import CAwalTerminal
import QuartzCore

// MARK: - Metal Rendering (Display Link)

extension TerminalView {

    func renderFrame() {
        guard !isCleanedUp else { return }
        guard needsRender else { return }
        // Don't present any frame to screen while the menu is still
        // waiting for layout to settle — Metal drawables bypass view alpha.
        guard !menuRenderPending else { return }
        guard let layer = metalLayer else { return }
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }
        guard let drawable = layer.nextDrawable() else { return }

        needsRender = false

        let viewportSize = layer.drawableSize

        // Advance loading animation (throttled to ~30fps to avoid starving scroll events)
        var currentLoadingPhase: Float? = nil
        if isWaitingForOutput || isGenerating || isLoadingResumeSessions {
            let now = CACurrentMediaTime()
            let elapsed = now - lastLoadingRenderTime
            if elapsed >= 0.033 {
                loadingPhase += 0.024
                if loadingPhase > 2.0 { loadingPhase -= 2.0 }
                lastLoadingRenderTime = now

                // Update spinner character for loading message
                if isWaitingForOutput, !loadingMessageText.isEmpty,
                   loadingSpinnerRow > 0, loadingSpinnerCol > 0,
                   let s = surface {
                    let spinnerChars: [Character] = ["◐", "◓", "◑", "◒"]
                    let idx = Int(loadingPhase * 2) % spinnerChars.count
                    let ch = spinnerChars[idx]
                    let ansi = "\u{1b}[s\u{1b}[\(loadingSpinnerRow);\(loadingSpinnerCol)H\u{1b}[2m\(ch)\u{1b}[0m\u{1b}[u"
                    let bytes = Array(ansi.utf8)
                    bytes.withUnsafeBufferPointer { ptr in
                        at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
                    }
                    updateCellBuffer()
                }

                // Schedule next loading frame after interval instead of continuous rendering
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
                    guard let self, self.isWaitingForOutput || self.isGenerating || self.isLoadingResumeSessions else { return }
                    // Don't render stale cell buffer during synchronized output
                    if let s = self.surface, at_surface_is_synchronized(s) {
                        // Re-schedule without rendering — sync will end soon
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
                            self?.needsRender = true
                        }
                        return
                    }
                    self.needsRender = true
                }
            }
            currentLoadingPhase = loadingPhase
        }

        // Only recompute visual overlays when content has changed, debounced to 100ms
        if contentDirty {
            let now = CACurrentMediaTime()
            if now - lastOverlayComputeTime >= 0.1 {
                cachedSearchHighlights = computeVisibleSearchHighlights()
                cachedFoldIndicators = computeFoldIndicators()
                cachedCodeBlockRows = applySyntaxHighlighting()
                cachedDiffRowColors = applyDiffHighlighting()
                lastOverlayComputeTime = now
                contentDirty = false
            }
        }

        cellBuffer.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            renderer.render(
                cells: baseAddress,
                cellCount: cellBuffer.count,
                gridCols: Int(termCols),
                gridRows: Int(termRows),
                cursorRow: Int(cursorRow),
                cursorCol: Int(cursorCol),
                cursorVisible: cursorVisible,
                cursorBlinkOn: cursorBlinkOn,
                drawable: drawable,
                viewportSize: CGSize(width: viewportSize.width, height: viewportSize.height),
                scale: layer.contentsScale,
                searchHighlights: cachedSearchHighlights.cells,
                currentHighlight: cachedSearchHighlights.currentIndex,
                foldIndicators: cachedFoldIndicators,
                codeBlockRows: cachedCodeBlockRows,
                diffRowColors: cachedDiffRowColors,
                loadingPhase: currentLoadingPhase
            )

            // Capture frame for session recording (only when content actually changed)
            if let recorder = sessionRecorder, recorder.isRecording {
                recorder.captureFrame(
                    cells: baseAddress,
                    cellCount: cellBuffer.count,
                    cursorRow: Int(cursorRow),
                    cursorCol: Int(cursorCol),
                    cursorVisible: cursorVisible,
                    surface: surface
                )
            }
        }

    }

    func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let dl = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            // Display link holds a strong reference via passRetained — safe to use
            let view = Unmanaged<TerminalView>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { [weak view] in
                view?.renderFrame()
            }
            return kCVReturnSuccess
        }

        // passRetained: display link holds a strong ref so the pointer can't dangle
        CVDisplayLinkSetOutputCallback(dl, callback, Unmanaged.passRetained(self).toOpaque())
        CVDisplayLinkStart(dl)
        self.displayLink = dl

        // Render the first frame immediately
        needsRender = true
        renderFrame()
    }

    func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            displayLink = nil
            // Balance the passRetained from startDisplayLink
            Unmanaged.passUnretained(self).release()
        }
    }
}
