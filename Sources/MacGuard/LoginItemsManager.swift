import Foundation
import AppKit

// MARK: — Types

enum LoginItemType: String, CaseIterable {
    case launchDaemon    = "LaunchDaemon"
    case launchAgent     = "LaunchAgent"
    case loginItem       = "LoginItem"
    case backgroundItem  = "BackgroundItem"
    case unknown         = "Unknown"

    var displayName: String {
        switch self {
        case .launchDaemon:   return "Launch Daemon"
        case .launchAgent:    return "Launch Agent"
        case .loginItem:      return "Login Item"
        case .backgroundItem: return "Background Item"
        case .unknown:        return "Unknown"
        }
    }
    var icon: String {
        switch self {
        case .launchDaemon:   return "gearshape.2.fill"
        case .launchAgent:    return "gearshape.fill"
        case .loginItem:      return "person.badge.clock.fill"
        case .backgroundItem: return "clock.arrow.2.circlepath"
        case .unknown:        return "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .launchDaemon:   return .red
        case .launchAgent:    return .orange
        case .loginItem:      return .blue
        case .backgroundItem: return .purple
        case .unknown:        return .gray
        }
    }
    // LaunchDaemons run as root — toggling them needs admin
    var requiresAdmin: Bool { self == .launchDaemon }
}

import SwiftUI  // Color used above needs this

struct LoginItem: Identifiable, Hashable {
    let id             = UUID()
    let identifier:      String        // bundle ID / launchd label
    let plistURL:        URL?          // path to .plist on disk
    let type:            LoginItemType
    let developerName:   String
    let developerID:     String        // Team ID
    let rawDisposition:  Int           // BTM disposition bitmask
    let associatedApp:   URL?          // resolved .app bundle if found

    // Disposition bitmask (from sfltool dumpbtm):
    // bit 0 (0x1) = enabled | bit 1 (0x2) = allowed by user
    // bit 2 (0x4) = visible in UI | bit 3 (0x8) = notified
    var isEnabled: Bool { (rawDisposition & 0x1) != 0 }
    var isAllowed: Bool { (rawDisposition & 0x2) != 0 }

    var displayName: String {
        if let app = associatedApp {
            return app.deletingPathExtension().lastPathComponent
        }
        if !developerName.isEmpty { return developerName }
        // Friendly fallback: capitalise the last meaningful segment of the identifier
        return identifier
            .components(separatedBy: ".")
            .filter { $0.count > 2 }
            .last
            .map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? identifier
    }

    var plistFileName: String {
        plistURL?.lastPathComponent ?? "\(identifier).plist"
    }

    var startupScope: String {
        switch type {
        case .launchDaemon: return "Runs at boot (as root)"
        case .launchAgent:  return "Runs at login (as you)"
        case .loginItem:    return "Opens at login"
        default:            return "Background"
        }
    }

    static func == (l: LoginItem, r: LoginItem) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: — LoginItemsManager

class LoginItemsManager: ObservableObject {
    @Published var items:         [LoginItem] = []
    @Published var isLoading      = false
    @Published var statusMessage  = ""
    @Published var needsFDA       = false   // Full Disk Access required for BTM

    private var loadedLabels = Set<String>()   // from launchctl list (built once per refresh)
    private let uid          = getuid()

    // MARK: — Refresh

    func refresh() {
        isLoading     = true
        statusMessage = "Loading background tasks…"
        items         = []
        needsFDA      = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Build loaded-label set from launchctl list (one call, no per-plist subprocess)
            // NOTE: launchctl list (no sudo) returns USER-domain services only.
            // sudo launchctl list returns SYSTEM-domain. We call both via osascript.
            self.buildLoadedLabelsCache()

            var parsed       = [LoginItem]()
            var usedBTM      = false

            // Primary: sfltool dumpbtm (requires Full Disk Access on macOS 13+)
            let btmOutput = self.run("/usr/bin/sfltool", ["dumpbtm"])
            if btmOutput.contains("Entry[") || btmOutput.contains("identifier:") {
                parsed  = self.parseBTM(btmOutput)
                usedBTM = true
            } else if btmOutput.lowercased().contains("operation not permitted") ||
                      btmOutput.lowercased().contains("permission denied") ||
                      btmOutput.isEmpty {
                // BTM is unreadable — Full Disk Access not granted
                // Fall through to directory scan only
            }

            // Supplement / fallback: scan plist directories directly
            // Catches items not in BTM (older macOS, manually placed plists)
            // and fills in when BTM is inaccessible
            let supplemental = self.scanPlistDirectories()
            var knownIDs     = Set(parsed.map { $0.identifier })
            for item in supplemental where !knownIDs.contains(item.identifier) {
                parsed.append(item)
                knownIDs.insert(item.identifier)
            }

            // Filter out Apple's own system services (they're not useful to show
            // in a user-facing manager — /System/Library entries)
            let filtered = parsed.filter { item in
                guard let url = item.plistURL else { return true }
                return !url.path.hasPrefix("/System/Library")
            }

            let sorted = filtered.sorted {
                // Enabled first, then by type severity, then alphabetical
                if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
                if $0.type != $1.type {
                    let order: [LoginItemType] = [.launchDaemon, .launchAgent, .loginItem, .backgroundItem, .unknown]
                    let li = order.firstIndex(of: $0.type) ?? 99
                    let ri = order.firstIndex(of: $1.type) ?? 99
                    return li < ri
                }
                return $0.displayName.lowercased() < $1.displayName.lowercased()
            }

            let enabledCnt  = sorted.filter { $0.isEnabled }.count
            let disabledCnt = sorted.filter { !$0.isEnabled }.count
            let adminCnt    = sorted.filter { $0.type.requiresAdmin }.count
            var msg         = "\(sorted.count) items · \(enabledCnt) enabled · \(disabledCnt) disabled"
            if adminCnt > 0 { msg += " · \(adminCnt) need admin" }
            if !usedBTM     { msg += " · (BTM unavailable — grant Full Disk Access for full results)" }

            DispatchQueue.main.async {
                self.items         = sorted
                self.isLoading     = false
                self.statusMessage = msg
                self.needsFDA      = !usedBTM
            }
        }
    }

    // MARK: — launchctl list cache (one call covers all user-domain services)
    private func buildLoadedLabelsCache() {
        // User domain
        let userList = run("/bin/launchctl", ["list"])
        // System domain (no sudo available here — use print to check specific labels later)
        loadedLabels = Set(
            userList.components(separatedBy: "\n")
                .compactMap { line -> String? in
                    let cols = line.components(separatedBy: "\t")
                    return cols.count >= 3 ? cols[2].trimmingCharacters(in: .whitespaces) : nil
                }
                .filter { !$0.isEmpty && $0 != "Label" }
        )
    }

    // MARK: — Parse sfltool dumpbtm

    private func parseBTM(_ output: String) -> [LoginItem] {
        let fm = FileManager.default
        var results = [LoginItem]()

        // sfltool dumpbtm separates entries with blank lines
        // Each entry looks like:
        //   Entry[N]
        //     url: file:///path/to/plist
        //     type: launchd            ← NOT "LaunchDaemon"/"LaunchAgent"
        //     disposition: [...] 0xN
        //     identifier: com.example.app
        //     developer name: Example Corp
        //     developer id: TEAMID
        let blocks = output.components(separatedBy: "\n\n")

        for block in blocks {
            guard block.contains("identifier:") || block.contains("url:") else { continue }
            let lines = block.components(separatedBy: "\n")

            var rawURL    = ""
            var rawType   = ""
            var disp      = 0
            var ident     = ""
            var devName   = ""
            var devID     = ""

            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if      t.hasPrefix("url:")              { rawURL  = val(t, "url:") }
                else if t.hasPrefix("type:")             { rawType = val(t, "type:") }
                else if t.hasPrefix("identifier:")       { ident   = val(t, "identifier:") }
                else if t.hasPrefix("developer name:")   { devName = val(t, "developer name:") }
                else if t.hasPrefix("developer id:")     { devID   = val(t, "developer id:") }
                else if t.hasPrefix("disposition:") {
                    // "disposition: [enabled, allowed, visible, notified] 0xf"
                    // Extract the trailing hex value — most reliable across macOS versions
                    if let hexToken = t.components(separatedBy: "]").last?
                        .trimmingCharacters(in: .whitespaces),
                       hexToken.hasPrefix("0x"),
                       let val = Int(hexToken.dropFirst(2), radix: 16) {
                        disp = val
                    } else {
                        // Fallback: parse flag names
                        if t.contains("enabled")  && !t.contains("not enabled")  { disp |= 0x1 }
                        if t.contains("allowed")  && !t.contains("not allowed")  { disp |= 0x2 }
                        if t.contains("visible")  && !t.contains("not visible")  { disp |= 0x4 }
                    }
                }
            }

            guard !ident.isEmpty || !rawURL.isEmpty else { continue }

            // Resolve plist URL
            let plistPath = rawURL
                .replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding ?? rawURL.replacingOccurrences(of: "file://", with: "")
            let plistURL: URL? = plistPath.isEmpty ? nil : {
                let u = URL(fileURLWithPath: plistPath)
                return fm.fileExists(atPath: u.path) ? u : nil
            }()

            // Derive identifier from plist filename if missing
            if ident.isEmpty, let u = plistURL {
                ident = u.deletingPathExtension().lastPathComponent
            }

            // Derive type from URL path — "type: launchd" doesn't distinguish daemon vs agent
            let itemType = deriveType(urlPath: plistPath, btmType: rawType)

            // For supplemental items not in BTM, check launchctl list for loaded state
            var finalDisp = disp
            if disp == 0 && loadedLabels.contains(ident) { finalDisp = 0x3 }

            let appURL = findAssociatedApp(identifier: ident)

            results.append(LoginItem(
                identifier:    ident,
                plistURL:      plistURL,
                type:          itemType,
                developerName: devName,
                developerID:   devID,
                rawDisposition: finalDisp,
                associatedApp: appURL
            ))
        }
        return results
    }

    // MARK: — Supplemental directory scan

    private func scanPlistDirectories() -> [LoginItem] {
        let fm   = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var results = [LoginItem]()

        let dirs: [(String, LoginItemType)] = [
            ("/Library/LaunchDaemons",         .launchDaemon),
            ("/Library/LaunchAgents",          .launchAgent),
            ("\(home)/Library/LaunchAgents",   .launchAgent),
        ]

        for (dirPath, type) in dirs {
            let dirURL = URL(fileURLWithPath: dirPath)
            guard let plists = try? fm.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil) else { continue }

            for plist in plists where plist.pathExtension == "plist" {
                guard let dict = NSDictionary(contentsOf: plist) else { continue }
                let label = (dict["Label"] as? String)
                    ?? plist.deletingPathExtension().lastPathComponent

                // Check loaded state from our pre-built cache (no extra subprocess)
                let isLoaded = loadedLabels.contains(label)

                // Also check system domain via launchctl print (fast targeted call)
                let systemLoaded: Bool
                if type == .launchDaemon {
                    let out = run("/bin/launchctl", ["print", "system/\(label)"])
                    systemLoaded = !out.contains("Bad request") &&
                                   !out.contains("Could not find")
                } else {
                    systemLoaded = false
                }

                let loaded = isLoaded || systemLoaded
                // bit 0 = enabled, bit 1 = allowed (we assume allowed for directory items)
                let disposition = loaded ? 0x3 : 0x2

                let appURL = findAssociatedApp(identifier: label)
                results.append(LoginItem(
                    identifier:     label,
                    plistURL:       plist,
                    type:           type,
                    developerName:  "",
                    developerID:    "",
                    rawDisposition: disposition,
                    associatedApp:  appURL
                ))
            }
        }
        return results
    }

    // MARK: — Type derivation
    // sfltool reports type "launchd" for both daemons and agents.
    // The URL path is the only reliable way to distinguish them.
    private func deriveType(urlPath: String, btmType: String) -> LoginItemType {
        if urlPath.contains("/LaunchDaemons/")           { return .launchDaemon   }
        if urlPath.contains("/LaunchAgents/")            { return .launchAgent    }
        let t = btmType.lowercased()
        if t == "app" || t == "login-item" || t == "loginitem" { return .loginItem }
        if t == "background" || t == "backgrounditem"    { return .backgroundItem }
        return .unknown
    }

    // MARK: — Find associated .app
    private func findAssociatedApp(identifier: String) -> URL? {
        let fm   = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let parts = identifier.components(separatedBy: ".")
            .filter { $0.count > 2 }
            .map    { $0.lowercased() }

        for dir in ["/Applications", "\(home)/Applications"] {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" {
                let plist = item.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: plist),
                   let bid  = dict["CFBundleIdentifier"] as? String {
                    if bid.lowercased() == identifier.lowercased()   { return item }
                    // Fuzzy: identifier starts with app's bundle ID (e.g. helper of the app)
                    if identifier.lowercased().hasPrefix(bid.lowercased()) { return item }
                }
                let appName = item.deletingPathExtension().lastPathComponent.lowercased()
                if parts.contains(where: { appName.contains($0) })  { return item }
            }
        }
        return nil
    }

    // MARK: — Toggle

    func toggle(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        item.isEnabled ? disable(item, completion: completion)
                       : enable(item,  completion: completion)
    }

    private func enable(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = false

            if let plist = item.plistURL {
                if item.type.requiresAdmin {
                    let s = "do shell script \"launchctl load -w '\(plist.path.esc)'\" with administrator privileges"
                    var err: NSDictionary?
                    NSAppleScript(source: s)?.executeAndReturnError(&err)
                    success = err == nil
                } else {
                    // Try modern bootstrap first, fall back to legacy load
                    let domain = "gui/\(self.uid)"
                    _ = self.run("/bin/launchctl", ["enable", "\(domain)/\(item.identifier)"])
                    let out = self.run("/bin/launchctl", ["bootstrap", domain, plist.path])
                    success = !out.lowercased().contains("error") || out.isEmpty
                    if !success {
                        let out2 = self.run("/bin/launchctl", ["load", "-w", plist.path])
                        success  = !out2.lowercased().contains("error")
                    }
                }
            } else {
                // SMAppService-registered item — no plist we can control
                let domain = "gui/\(self.uid)"
                _ = self.run("/bin/launchctl", ["enable", "\(domain)/\(item.identifier)"])
                success = true
            }

            if success { self.refresh() }
            DispatchQueue.main.async {
                completion(success,
                    success ? "✅ \(item.displayName) enabled"
                            : "❌ Failed to enable \(item.displayName)")
            }
        }
    }

    private func disable(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = false

            if let plist = item.plistURL {
                if item.type.requiresAdmin {
                    let e = plist.path.esc
                    let s = "do shell script \"launchctl unload -w '\(e)'\" with administrator privileges"
                    var err: NSDictionary?
                    NSAppleScript(source: s)?.executeAndReturnError(&err)
                    success = err == nil
                } else {
                    let domain = "gui/\(self.uid)"
                    // Modern: bootout + disable (persists across reboots)
                    _ = self.run("/bin/launchctl", ["bootout",  "\(domain)/\(item.identifier)"])
                    _ = self.run("/bin/launchctl", ["disable",  "\(domain)/\(item.identifier)"])
                    // Legacy fallback: unload -w (sets Disabled key in plist)
                    _ = self.run("/bin/launchctl", ["unload", "-w", plist.path])
                    success = true
                }
            } else {
                let domain = "gui/\(self.uid)"
                _ = self.run("/bin/launchctl", ["disable", "\(domain)/\(item.identifier)"])
                success = true
            }

            if success { self.refresh() }
            DispatchQueue.main.async {
                completion(success,
                    success ? "✅ \(item.displayName) disabled"
                            : "❌ Failed to disable \(item.displayName)")
            }
        }
    }

    // MARK: — Remove
    func remove(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        guard let plist = item.plistURL else {
            DispatchQueue.main.async {
                completion(false, "❌ No plist file — cannot remove (SMAppService items must be removed by the app itself)")
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = false

            if item.type.requiresAdmin {
                let e = plist.path.esc
                let s = """
                do shell script "launchctl bootout system/\(item.identifier.esc) 2>/dev/null; \
                launchctl unload -w '\(e)' 2>/dev/null; \
                rm -f '\(e)'" with administrator privileges
                """
                var err: NSDictionary?
                NSAppleScript(source: s)?.executeAndReturnError(&err)
                success = err == nil
            } else {
                let domain = "gui/\(self.uid)"
                _ = self.run("/bin/launchctl", ["bootout", "\(domain)/\(item.identifier)"])
                _ = self.run("/bin/launchctl", ["disable", "\(domain)/\(item.identifier)"])
                success = (try? FileManager.default.removeItem(at: plist)) != nil
            }

            if success { self.refresh() }
            DispatchQueue.main.async {
                completion(success,
                    success ? "✅ \(item.displayName) removed"
                            : "❌ Failed to remove \(item.displayName)")
            }
        }
    }

    // MARK: — Helpers
    func revealInFinder(_ item: LoginItem) {
        if let url = item.plistURL {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        } else if let url = item.associatedApp {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String {
        let task = Process()
        task.executableURL  = URL(fileURLWithPath: path)
        task.arguments      = args
        let pipe            = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()   // stderr isolated — never mixed into output
        guard (try? task.run()) != nil else { return "" }
        let killer = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        killer.cancel()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func val(_ line: String, _ prefix: String) -> String {
        line.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var esc: String { replacingOccurrences(of: "'", with: "'\\''") }
}
