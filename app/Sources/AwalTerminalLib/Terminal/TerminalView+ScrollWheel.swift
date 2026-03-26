import AppKit
import CAwalTerminal

// MARK: - Scroll Wheel (Scrollback)

extension TerminalView {

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface, appState == .terminal else { return }

        // Dismiss autocomplete popup on scroll
        hideCompletions()

        let delta = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas

        // Reset accumulator at the start of a new trackpad gesture
        if precise && event.phase == .began {
            scrollAccumulator = 0.0
        }

        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode > 0 {
            // Mouse reporting enabled — send scroll as mouse button 4/5 (up/down)
            let location = convert(event.locationInWindow, from: nil)
            let col = Int(location.x / cellWidth) + 1
            let row = Int(location.y / cellHeight) + 1  // Will be flipped below
            let flippedRow = Int(termRows) - row + 1

            let lines: Int
            if precise {
                scrollAccumulator += delta / cellHeight
                lines = Int(scrollAccumulator)
                scrollAccumulator -= CGFloat(lines)
            } else {
                lines = max(1, Int(abs(delta) / 3.0 + 0.5)) * (delta > 0 ? 1 : -1)
            }

            let absLines = abs(lines)
            guard absLines > 0 else { return }

            let sgrMode = at_surface_get_sgr_mouse(s)
            for _ in 0..<absLines {
                let button = lines > 0 ? 64 : 65 // scroll up : scroll down
                let seq: [UInt8]
                if sgrMode {
                    let str = "\u{1b}[\(button);\(col);\(flippedRow)M"
                    seq = Array(str.utf8)
                } else {
                    // X10 encoding
                    seq = [0x1b, 0x5b, 0x4d,
                           UInt8(32 + button),
                           UInt8(32 + col),
                           UInt8(32 + flippedRow)]
                }
                seq.withUnsafeBufferPointer { ptr in
                    _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
                }
            }
            return
        }

        // Normal scrollback
        let lines: Int
        if precise {
            scrollAccumulator += delta / cellHeight
            lines = Int(scrollAccumulator)
            scrollAccumulator -= CGFloat(lines)
        } else {
            lines = Int(delta / 3.0)
        }
        if lines != 0 {
            at_surface_scroll_viewport(s, Int32(lines))
            let offset = at_surface_get_viewport_offset(s)
            // Scrolling down near the bottom during active output? Snap to live view.
            if lines < 0 && offset > 0 && offset <= Int32(termRows) {
                at_surface_scroll_viewport(s, -offset)
                userScrolledUp = false
            } else {
                userScrolledUp = offset > 0
            }
            showOrHideScrollToBottom()
            updateCellBuffer()
            needsRender = true
        }
    }
}
