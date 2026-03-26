import AppKit

// MARK: - Screenshot to Session

extension TerminalView {

    func captureScreenshotAndPastePath() {
        guard let _ = surface else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let path = NSTemporaryDirectory() + "awal-screenshot-\(timestamp).png"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", path]
            do {
                try process.run()
            } catch {
                return
            }
            process.waitUntilExit()

            let status = process.terminationStatus

            // Exit code 0 = success, 1 = user cancelled
            if status == 0, FileManager.default.fileExists(atPath: path) {
                let escaped = self?.shellEscape(path) ?? path
                DispatchQueue.main.async {
                    self?.queuePtyWrite(Array(escaped.utf8))
                }
            } else if status != 0, status != 1 {
                // Permission denied or other error — show alert on main thread
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording Permission Required"
                    alert.informativeText = "Awal Terminal needs Screen Recording permission to capture screenshots.\n\nPlease grant access in System Settings → Privacy & Security → Screen Recording, then restart the app."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
