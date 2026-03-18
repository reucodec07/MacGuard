import AppKit
import SwiftUI

extension Notification.Name {
    static let openMacGuardWindow = Notification.Name("openMacGuardWindow")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

class MenuBarController: NSObject {
    private var statusItem:   NSStatusItem!
    private var popover:      NSPopover!
    private var eventMonitor: Any?

    let monitor = ProcessMonitor.shared

    override init() {
        super.init()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        monitor.setBackground()
        monitor.start()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "shield.lefthalf.filled",
                           accessibilityDescription: "MacGuard")
        icon?.isTemplate = true
        button.image  = icon
        button.action = #selector(togglePopover(_:))
        button.target = self
        // leftMouseUp fires after the click completes — avoids the popover
        // immediately re-closing when the mouse-up event propagates
        button.sendAction(on: [.leftMouseUp])
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 530)
        // .applicationDefined: we control dismissal via the global event monitor.
        // Do NOT use .transient — it races with the event monitor on slower machines.
        popover.behavior    = .applicationDefined
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(monitor: monitor)
        )
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            openPopover(button: button)
        }
    }

    private func openPopover(button: NSView) {
        monitor.setForeground()
        monitor.refresh()

        // CRITICAL: show BEFORE doing anything else with the popover window.
        // Any call to popover.contentViewController?.view.window after show()
        // detaches the popover from its anchor — that's what caused it to float
        // to screen centre. We do nothing with the window here.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Dismiss on outside click
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.closePopover() }
    }

    private func closePopover() {
        popover.performClose(nil)
        monitor.setBackground()
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}
