import Foundation
import ServiceManagement

class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published var isEnabled: Bool = false

    init() {
        checkStatus()
    }

    func checkStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func enable() {
        do {
            try SMAppService.mainApp.register()
            isEnabled = SMAppService.mainApp.status == .enabled
            print("✅ Launch at login enabled")
        } catch {
            print("❌ Failed to enable launch at login: \(error)")
        }
    }

    func disable() {
        do {
            try SMAppService.mainApp.unregister()
            isEnabled = SMAppService.mainApp.status == .enabled
            print("✅ Launch at login disabled")
        } catch {
            print("❌ Failed to disable launch at login: \(error)")
        }
    }

    func toggle() {
        isEnabled ? disable() : enable()
    }

    var statusLabel: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "On — starts with Mac"
        case .notRegistered:     return "Off"
        case .requiresApproval:  return "Needs approval in Settings"
        case .notFound:          return "Not found"
        @unknown default:        return "Unknown"
        }
    }

    var statusColor: String {
        SMAppService.mainApp.status == .enabled ? "green" : "secondary"
    }
}
