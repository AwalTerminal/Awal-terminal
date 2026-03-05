import AppKit

final class NotificationManager {

    static let shared = NotificationManager()

    private let enabledKey = "NotificationsEnabled"
    private let cooldown: TimeInterval = 30
    private var lastNotificationTime: Date = .distantPast

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true // default on
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    private init() {}

    func notifyIdleIfNeeded(modelName: String) {
        guard isEnabled else { return }
        guard !NSApplication.shared.isActive else { return }
        guard Date().timeIntervalSince(lastNotificationTime) >= cooldown else { return }

        lastNotificationTime = Date()

        // Dock icon bounce
        NSApplication.shared.requestUserAttention(.informationalRequest)

        // Best-effort notification via osascript
        let escaped = modelName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped) is waiting for input\" with title \"Awal Terminal\""
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}
