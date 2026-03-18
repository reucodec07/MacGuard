import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        menuBarController = MenuBarController()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMainWindow),
            name: .openMacGuardWindow,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: .openSettingsWindow,
            object: nil
        )
    }

    func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Open MacGuard",
            action: #selector(openMainWindow),
            keyEquivalent: "o"))
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit MacGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        NSApplication.shared.mainMenu = mainMenu
    }
    @objc func openSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.isReleasedWhenClosed = false // <-- FIX: Prevents AppKit from over-releasing the window
            settingsWindow?.title = "MacGuard Settings"
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow?.center()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: settingsWindow,
                queue: .main
            ) { [weak self] _ in
                self?.settingsWindow = nil
                if self?.window == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }



    @objc func openMainWindow() {
        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.isReleasedWhenClosed = false // <-- FIX: Prevents AppKit from over-releasing the window
            window?.title = "MacGuard"
            window?.contentView = NSHostingView(rootView: ContentView())
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Return to accessory when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
            if self?.settingsWindow == nil { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
