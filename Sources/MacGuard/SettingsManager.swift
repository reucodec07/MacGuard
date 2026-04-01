import Foundation
import Combine

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // CPU auto-kill
    @Published var autoKillEnabled: Bool {
        didSet { defaults.set(autoKillEnabled, forKey: "autoKillEnabled") }
    }
    @Published var autoKillThreshold: Double {
        didSet { defaults.set(autoKillThreshold, forKey: "autoKillThreshold") }
    }

    // Notification thresholds
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var cpuAlertThreshold: Double {
        didSet { defaults.set(cpuAlertThreshold, forKey: "cpuAlertThreshold") }
    }
    @Published var ramAlertThreshold: Double {
        didSet { defaults.set(ramAlertThreshold, forKey: "ramAlertThreshold") }
    }

    // Sort preference
    @Published var sortMode: SortMode {
        didSet { defaults.set(sortMode.rawValue, forKey: "sortMode") }
    }

    // AI
    @Published var anthropicApiKey: String {
        didSet { defaults.set(anthropicApiKey, forKey: "anthropicApiKey") }
    }

    private init() {
        autoKillEnabled    = defaults.bool(forKey: "autoKillEnabled")
        autoKillThreshold  = defaults.object(forKey: "autoKillThreshold")  as? Double ?? 80.0
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        cpuAlertThreshold  = defaults.object(forKey: "cpuAlertThreshold")  as? Double ?? 80.0
        ramAlertThreshold  = defaults.object(forKey: "ramAlertThreshold")  as? Double ?? 500.0
        let raw            = defaults.string(forKey: "sortMode") ?? SortMode.cpu.rawValue
        sortMode           = SortMode(rawValue: raw) ?? .cpu
        anthropicApiKey    = defaults.string(forKey: "anthropicApiKey") ?? ""
    }
}
