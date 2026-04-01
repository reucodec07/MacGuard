import Foundation
import UserNotifications

class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    // Lazily resolved — never touched until app is fully launched
    private var center: UNUserNotificationCenter? {
        // Crashes if called without a valid bundle identifier
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval = 30.0
    private init() {}

    func requestPermission() {
        guard let c = center else { return }
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                SettingsManager.shared.notificationsEnabled = granted
            }
        }
    }

    func checkPermission() {
        guard let c = center else { return }
        c.getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus != .authorized {
                    SettingsManager.shared.notificationsEnabled = false
                }
            }
        }
    }

    func checkProcess(_ process: AppProcess) {
        let settings = SettingsManager.shared
        guard settings.notificationsEnabled else { return }
        if process.cpuPercent > settings.cpuAlertThreshold {
            fire(id: "cpu-\(process.pid)",
                 title: "⚠️ High CPU — \(process.name)",
                 body: "\(process.name) is using \(String(format: "%.1f", process.cpuPercent))% CPU",
                 subtitle: "PID \(process.pid)")
        }
        if process.memoryMB > settings.ramAlertThreshold {
            fire(id: "ram-\(process.pid)",
                 title: "🧠 High Memory — \(process.name)",
                 body: "\(process.name) is using \(String(format: "%.0f MB", process.memoryMB)) RAM",
                 subtitle: "PID \(process.pid)")
        }
    }

    private func fire(id: String, title: String, body: String, subtitle: String) {
        guard let c = center else { return }
        if let last = lastNotified[id],
           Date().timeIntervalSince(last) < cooldown { return }
        lastNotified[id] = Date()
        let content      = UNMutableNotificationContent()
        content.title    = title
        content.body     = body
        content.subtitle = subtitle
        content.sound    = .default
        c.add(UNNotificationRequest(identifier: UUID().uuidString,
                                    content: content, trigger: nil)) { _ in }
    }

    func notifyAutoKill(processName: String, cpu: Double) {
        fire(id: "autokill-\(processName)",
             title: "🛑 Process Terminated",
             body: "\(processName) was closed for using \(Int(cpu))% CPU consistently.",
             subtitle: "MacGuard Auto-Kill")
    }

    func clearAll() {
        guard let c = center else { return }
        c.removeAllDeliveredNotifications()
        c.removeAllPendingNotificationRequests()
        lastNotified.removeAll()
    }
}
