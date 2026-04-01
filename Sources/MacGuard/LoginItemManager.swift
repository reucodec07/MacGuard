import Foundation
import ServiceManagement
import SwiftUI
import AppKit
import os.log
import os.signpost

/// Abstract integration over SMAppService testing bounds.
protocol SMServiceControlling: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct RealSMServiceController: SMServiceControlling {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Abstract URL opening for testability.
protocol URLOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct RealURLOpener: URLOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Simulated mock explicitly built for test ingestion tracking UI state shifts natively.
final class FakeSMServiceController: SMServiceControlling, @unchecked Sendable {
    var mockedStatus: SMAppService.Status = .notRegistered
    var shouldThrowRegister: Error? = nil
    var shouldThrowUnregister: Error? = nil
    var stickyStatus: Bool = false // If true, register() doesn't change status to .enabled
    
    var status: SMAppService.Status { mockedStatus }
    
    func register() throws {
        if let err = shouldThrowRegister { throw err }
        if !stickyStatus { mockedStatus = .enabled }
    }
    
    func unregister() throws {
        if let err = shouldThrowUnregister { throw err }
        mockedStatus = .notRegistered
    }
}

@MainActor
class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager(controller: RealSMServiceController(), urlOpener: RealURLOpener())

    @Published private(set) var status: SMAppService.Status = .notRegistered {
        didSet {
            if oldValue != status {
                isEnabled = status == .enabled
                logger.info("Status transitioned: \(String(describing: oldValue)) -> \(String(describing: self.status))")
            }
        }
    }
    @Published var isEnabled: Bool = false
    @Published var isBusy: Bool = false

    private let controller: any SMServiceControlling
    private let urlOpener: any URLOpening
    private let logger = Logger(subsystem: "com.macguard", category: "SMAppService")
    
    init(controller: any SMServiceControlling, urlOpener: any URLOpening) {
        self.controller = controller
        self.urlOpener = urlOpener
        checkStatus()
    }
    
    func checkStatus() {
        let newStatus = controller.status
        if status != newStatus {
            status = newStatus
        }
    }

    @discardableResult
    func enable() async -> (success: Bool, message: String) {
        isBusy = true
        defer { isBusy = false }
        
        do {
            try controller.register()
            checkStatus()
            return (true, "✅ Launch at login enabled")
        } catch {
            let msg = mapError(error)
            return (false, msg)
        }
    }

    @discardableResult
    func disable() async -> (success: Bool, message: String) {
        isBusy = true
        defer { isBusy = false }
        
        do {
            try controller.unregister()
            checkStatus()
            return (true, "✅ Launch at login disabled")
        } catch {
            let msg = mapError(error)
            return (false, msg)
        }
    }

    func toggle() async {
        if status == .requiresApproval {
            openLoginItemsSettings()
        } else {
            _ = status == .enabled ? await disable() : await enable()
        }
    }

    func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        urlOpener.open(url)
    }

    private func mapError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case 10: return "Approval required. Please enable MacGuard in System Settings."
        default: return "❌ Error: \(error.localizedDescription)"
        }
    }

    var canToggle: Bool {
        if isBusy || status == .notFound { return false }
        return true
    }

    var statusLabel: String {
        switch status {
        case .enabled:           return "On — starts with Mac"
        case .notRegistered:     return "Off"
        case .requiresApproval:  return "Needs approval in Settings"
        case .notFound:          return "Not found"
        @unknown default:        return "Unknown"
        }
    }

    var statusColor: Color {
        status == .enabled ? .green : (status == .requiresApproval ? .orange : .secondary)
    }

    var actionLabel: String {
        switch status {
        case .enabled:           return "Disable"
        case .requiresApproval:  return "Open Settings"
        default:                 return "Enable"
        }
    }

    var buttonTintColor: Color {
        switch status {
        case .enabled:           return .green
        case .requiresApproval:  return .orange
        default:                 return .accentColor
        }
    }

    var statusHelp: String {
        status == .requiresApproval ? "Approval required. Open Settings -> Login Items and enable MacGuard." : ""
    }
}
