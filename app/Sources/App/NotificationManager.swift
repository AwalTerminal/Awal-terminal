import AppKit
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    private let enabledKey = "NotificationsEnabled"
    private let cooldown: TimeInterval = 30
    private var lastNotificationTime: Date = .distantPast
    private var authorized = false

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

    private override init() {
        super.init()
        // UNUserNotificationCenter.current() crashes when the app has no bundle identifier
        // (e.g. running via `swift build` without a .app bundle).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func notifyIdleIfNeeded(modelName: String) {
        guard isEnabled else { return }
        guard !NSApplication.shared.isActive else { return }
        guard Date().timeIntervalSince(lastNotificationTime) >= cooldown else { return }

        lastNotificationTime = Date()

        // Dock icon bounce
        NSApplication.shared.requestUserAttention(.informationalRequest)

        // Native notification (shows app icon automatically)
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = "Awal Terminal"
            content.body = "\(modelName) is waiting for input"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        } else {
            // Fallback to osascript if not authorized
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

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
