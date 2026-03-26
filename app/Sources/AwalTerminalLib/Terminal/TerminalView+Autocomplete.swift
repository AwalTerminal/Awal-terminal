import AppKit
import CAwalTerminal

// MARK: - Autocomplete

extension TerminalView {

    func scheduleCompletionUpdate() {
        completionDebounceTimer?.invalidate()
        completionDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.updateCompletions()
        }
    }

    func updateCompletions() {
        guard activeModelName.isEmpty || activeModelName == "Shell" else {
            hideCompletions()
            return
        }
        guard let s = surface else { return }
        guard let cStr = at_surface_get_input_line(s) else {
            hideCompletions()
            return
        }
        let inputLine = String(cString: cStr)
        at_free_string(cStr)

        guard !inputLine.trimmingCharacters(in: .whitespaces).isEmpty else {
            hideCompletions()
            return
        }

        var allCompletions: [Completion] = []
        for provider in completionProviders {
            allCompletions.append(contentsOf: provider.completions(for: inputLine, cursorPos: inputLine.count))
        }

        guard !allCompletions.isEmpty else {
            hideCompletions()
            return
        }

        if completionPopup == nil {
            completionPopup = CompletionPopupView(frame: .zero)
            completionPopup!.onAccept = { [weak self] completion in
                self?.acceptCompletion(completion)
            }
            completionPopup!.onDismiss = { [weak self] in
                self?.hideCompletions()
            }
            addSubview(completionPopup!)
        }

        // Position below cursor
        let x = CGFloat(cursorCol) * cellWidth
        let y = bounds.height - CGFloat(cursorRow + 1) * cellHeight
        completionPopup?.show(completions: allCompletions, at: NSPoint(x: x, y: y))
    }

    func hideCompletions() {
        completionPopup?.hide()
    }

    func acceptCompletion(_ completion: Completion) {
        guard let s = surface else { return }
        let bytes = Array(completion.insertText.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
    }
}
