#if DEBUG
import Foundation

/// Collects debug log entries for display in the debug console panel.
final class DebugLogCollector {
    static let shared = DebugLogCollector()
    static let logDidAppend = Notification.Name("DebugLogCollectorDidAppend")

    var entries: [String] = []

    private init() {}

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = Self.formatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] \(filename):\(line) — \(message)"

        if Thread.isMainThread {
            entries.append(entry)
            NotificationCenter.default.post(name: Self.logDidAppend, object: self, userInfo: ["entry": entry])
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries.append(entry)
                NotificationCenter.default.post(name: Self.logDidAppend, object: self, userInfo: ["entry": entry])
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Log a debug message to both the debug console and NSLog.
func debugLog(_ message: String, file: String = #file, line: Int = #line) {
    DebugLogCollector.shared.log(message, file: file, line: line)
    NSLog("%@", message)
}

#else

/// No-op in release builds.
@inline(__always)
func debugLog(_ message: String, file: String = #file, line: Int = #line) {}

#endif
