import AppKit

/// Checks GitHub Releases for new versions and notifies the app when an update is available.
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// Posted on the main queue when update availability changes.
    static let updateAvailable = Notification.Name("UpdateChecker.updateAvailable")

    struct ReleaseInfo {
        let version: String       // e.g. "0.11.0"
        let tagName: String       // e.g. "v0.11.0"
        let body: String          // release notes markdown
        let htmlURL: String       // GitHub release page URL
    }

    private(set) var latestRelease: ReleaseInfo?
    private(set) var isUpdateAvailable: Bool = false

    private var timer: Timer?
    private let checkInterval: TimeInterval = 4 * 60 * 60  // 4 hours

    private init() {}

    // MARK: - Lifecycle

    func start() {
        // Initial check after a short delay to not block launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkNow()
        }
        // Periodic checks
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Manual Check

    func checkNow(completion: ((_ hasUpdate: Bool, _ error: Error?) -> Void)? = nil) {
        let url = URL(string: "https://api.github.com/repos/AwalTerminal/Awal-terminal/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async { completion?(false, error) }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion?(false, nil) }
                return
            }

            let body = json["body"] as? String ?? ""
            let htmlURL = json["html_url"] as? String ?? ""
            let remoteVersion = self.parseVersion(tagName)

            let release = ReleaseInfo(
                version: remoteVersion,
                tagName: tagName,
                body: body,
                htmlURL: htmlURL
            )

            let currentVersion = self.currentAppVersion()
            let hasUpdate = self.compareVersions(remote: remoteVersion, current: currentVersion)

            DispatchQueue.main.async {
                self.latestRelease = release
                self.isUpdateAvailable = hasUpdate
                if hasUpdate {
                    NotificationCenter.default.post(name: UpdateChecker.updateAvailable, object: nil)
                }
                completion?(hasUpdate, nil)
            }
        }.resume()
    }

    // MARK: - Homebrew Detection

    var isHomebrewInstall: Bool {
        let appPath = Bundle.main.bundlePath
        return appPath.contains("/opt/homebrew/") || appPath.contains("/usr/local/Caskroom/")
    }

    // MARK: - Version Parsing

    func currentAppVersion() -> String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        // Fallback: git tag (debug builds)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["describe", "--tags", "--abbrev=0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let tag = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return parseVersion(tag)
        } catch {
            return "0.0.0"
        }
    }

    /// Strips leading "v" and returns the numeric version string.
    private func parseVersion(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s = String(s.dropFirst())
        }
        return s
    }

    /// Returns true if `remote` is newer than `current` using semantic versioning.
    private func compareVersions(remote: String, current: String) -> Bool {
        let r = versionTuple(remote)
        let c = versionTuple(current)
        if r.major != c.major { return r.major > c.major }
        if r.minor != c.minor { return r.minor > c.minor }
        return r.patch > c.patch
    }

    private func versionTuple(_ version: String) -> (major: Int, minor: Int, patch: Int) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    // MARK: - Update Actions

    /// Shows the update alert. Call from the main thread.
    func showUpdateAlert() {
        guard let release = latestRelease, isUpdateAvailable else {
            showUpToDateAlert()
            return
        }

        let alert = NSAlert.branded()
        alert.messageText = "Update Available: v\(release.version)"

        // Truncate long release notes
        let notes = release.body.isEmpty ? "A new version is available." : release.body
        let truncated = notes.count > 500 ? String(notes.prefix(500)) + "…" : notes
        alert.informativeText = "Current version: v\(currentAppVersion())\n\n\(truncated)"
        alert.alertStyle = .informational

        if isHomebrewInstall {
            alert.addButton(withTitle: "Update via Homebrew")
        } else {
            alert.addButton(withTitle: "Download Update")
        }
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if isHomebrewInstall {
                updateViaHomebrew()
            } else {
                openReleasePage()
            }
        }
    }

    func showUpToDateAlert() {
        let alert = NSAlert.branded()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Awal Terminal v\(currentAppVersion()) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func updateViaHomebrew() {
        // Open macOS Terminal.app and run the upgrade command
        let script = "tell application \"Terminal\"\nactivate\ndo script \"brew upgrade awal-terminal && echo 'Update complete! Restart Awal Terminal.'\"\nend tell"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func openReleasePage() {
        guard let release = latestRelease,
              let url = URL(string: release.htmlURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
