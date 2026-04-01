import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy correctly for Phase 13 behavior
        NSApp.setActivationPolicy(.accessory)
        
        menuBarController = MenuBarController()
        ProcessMonitor.shared.start()
        
        NotificationCenter.default.addObserver(forName: .openMacGuardWindow, object: nil, queue: .main) { [weak self] _ in
            self?.showMainWindow()
        }
        
        NotificationCenter.default.addObserver(forName: .openSettingsWindow, object: nil, queue: .main) { [weak self] _ in
            self?.showSettingsWindow()
        }
        
        // Show the main window on first launch so the user knows it's working
        showMainWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.title = "MacGuard"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main")
        
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.title = "MacGuard Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.isReleasedWhenClosed = false
        
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let openMacGuardWindow = Notification.Name("openMacGuardWindow")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    static let refreshCurrentSection = Notification.Name("refreshCurrentSection")
    static let focusSearchField = Notification.Name("focusSearchField")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()


