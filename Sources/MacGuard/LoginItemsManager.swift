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
    var id: String { identifier }
    let identifier:      String        // bundle ID / launchd label
    let plistURL:        URL?          // path to .plist on disk
    let type:            LoginItemType
    let developerName:   String
    let developerID:     String        // Team ID
    var rawDisposition:  Int           // BTM disposition bitmask
    var associatedApp:   URL?          // resolved .app bundle if found

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

    static func == (l: LoginItem, r: LoginItem) -> Bool { l.identifier == r.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

// MARK: — LoginItemsManager
import UniformTypeIdentifiers
import os.log
import os.signpost

@MainActor
class LoginItemsManager: ObservableObject {
    @Published var items:         [LoginItem] = []
    @Published var isLoading      = false
    @Published var statusMessage  = ""
    @Published var needsFDA       = false   // Full Disk Access required for BTM

    private let uid = getuid()
    nonisolated private let logger = Logger(subsystem: "com.macguard", category: "LoginItems")
    
    // Refresh generation token for overlapping cancellations
    private var refreshGeneration = 0
    private var currentRefreshTask: Task<Void, Never>?
    private var sources: [DispatchSourceFileSystemObject] = []
    
    #if DEBUG
    var refreshCount = 0
    var btmParseCount = 0
    var lastRefreshDuration: TimeInterval = 0
    var diagnostics: [String: Any] {
        [
            "refreshCount": refreshCount,
            "btmParseCount": btmParseCount,
            "lastRefreshDuration": lastRefreshDuration,
            "watchedPaths": sources.count
        ]
    }
    #endif

    init(watchPaths: [String]? = nil) {
        setupWatchers(paths: watchPaths)
    }

    private func setupWatchers(paths overridePaths: [String]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "\(home)/Library/LaunchAgents"]
        
        for path in paths {
            let fd = open(path, O_EVTONLY)
            if fd == -1 {
                logger.error("Failed to open watcher for \(path): \(String(cString: strerror(errno)))")
                continue 
            }
            
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename],
                queue: DispatchQueue.main
            )
            var debounceWorkItem: DispatchWorkItem?
            source.setEventHandler { [weak self] in
                debounceWorkItem?.cancel()
                let task = DispatchWorkItem { self?.refresh() }
                debounceWorkItem = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    // MARK: — Refresh

    func refresh() {
        refreshGeneration += 1
        let gen = refreshGeneration
        #if DEBUG
        refreshCount += 1
        #endif
        
        currentRefreshTask?.cancel()
        currentRefreshTask = Task { await asyncRefresh(generation: gen) }
    }

    @MainActor
    private func asyncRefresh(generation: Int) async {
        isLoading     = true
        statusMessage = "Loading background tasks…"
        items         = []
        needsFDA      = false

        let t0 = Date()
        #if DEBUG
        let start = Date()
        #endif
        let (sortedItems, msg, fda) = await Task(priority: .userInitiated) { [logger] () -> ([LoginItem], String, Bool) in
            let signposter = OSSignposter(logger: logger)
            let spSys = signposter.beginInterval("SystemCache_build", id: .exclusive)
            
            // 1. Get Loaded Labels
            let userList = await ProcessRunner.shared.run("/bin/launchctl", ["list"]).stdout
            let loadedLabels = Set(
                userList.components(separatedBy: "\n")
                    .compactMap { line -> String? in
                        let cols = line.components(separatedBy: "\t")
                        return cols.count >= 3 ? cols[2].trimmingCharacters(in: .whitespaces) : nil
                    }
                    .filter { !$0.isEmpty && $0 != "Label" }
            )
            
            // System Cache single-pass execution
            let tCache = Date()
            let systemCache = await LoginItemsCaches.shared.getSystemCache()
            
            let cpuCnt = max(2, ProcessInfo.processInfo.activeProcessorCount)
            let fallbackLimiter = ConcurrentLimiter(limit: min(4, cpuCnt))
            logger.debug("System cache built in \(Date().timeIntervalSince(tCache))s")
            signposter.endInterval("SystemCache_build", spSys)

            var appCache = await LoginItemsCaches.shared.getAppCache()
            var parsed = [LoginItem]()
            var usedBTM = false
            
            let spBtm = signposter.beginInterval("BTM_dump", id: .exclusive)
            let tBtm = Date()
            // 2. Dump BTM
            let btmOutput = await ProcessRunner.shared.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 5.0).stdout
            logger.debug("Dump BTM finished in \(Date().timeIntervalSince(tBtm))s")

            if btmOutput.contains("Entry[") || btmOutput.contains("identifier:") {
                let tParse = Date()
                parsed = await Self.parseBTM(btmOutput, loadedLabels: loadedLabels, systemCache: systemCache, fallbackLimiter: fallbackLimiter, cache: &appCache)
                #if DEBUG
                btmParseCount += 1
                #endif
                logger.debug("Parse BTM finished in \(Date().timeIntervalSince(tParse))s")
                usedBTM = true
            } else if btmOutput.lowercased().contains("operation not permitted") ||
                      btmOutput.lowercased().contains("permission denied") ||
                      btmOutput.isEmpty {
                // Fall through to directory scan only (Full Disk Access missing)
            }
            signposter.endInterval("BTM_dump", spBtm)
            
            let spDir = signposter.beginInterval("DirScan", id: .exclusive)
            let tScan = Date()
            // 3. Scan Plist Directories
            let supplemental = await Self.scanPlistDirectories(loadedLabels: loadedLabels, systemCache: systemCache, fallbackLimiter: fallbackLimiter)
            logger.debug("Directory Scan finished in \(Date().timeIntervalSince(tScan))s")
            signposter.endInterval("DirScan", spDir)
            
            var knownIDs = Set(parsed.map { $0.identifier })
            for item in supplemental where !knownIDs.contains(item.identifier) {
                parsed.append(item)
                knownIDs.insert(item.identifier)
            }

            // 4. Resolve Associated Apps Concurrently
            let spApp = signposter.beginInterval("AssocApp_resolve", id: .exclusive)
            let uniqueIDs = Array(Set(parsed.map { $0.identifier }).filter { appCache[$0] == nil })
            
            await withTaskGroup(of: (String, URL?).self) { group in
                var active = 0
                for ident in uniqueIDs {
                    if active >= min(4, cpuCnt) {
                        if let res = await group.next(), let url = res.1 { appCache[res.0] = url }
                        active -= 1
                    }
                    group.addTask {
                        let url = await Self.findAssociatedApp(identifier: ident)
                        return (ident, url)
                    }
                    active += 1
                }
                for await res in group {
                    if let url = res.1 { appCache[res.0] = url }
                }
            }
            
            await LoginItemsCaches.shared.updateAppCache(appCache)
            
            for i in parsed.indices {
                if let url = appCache[parsed[i].identifier] {
                    parsed[i].associatedApp = url
                }
            }
            signposter.endInterval("AssocApp_resolve", spApp)

            let spSort = signposter.beginInterval("Merge_sort", id: .exclusive)
            // Filter out Apple's own system services
            let filtered = parsed.filter { item in
                guard let url = item.plistURL else { return true }
                return !url.path.hasPrefix("/System/Library")
            }

            let sorted = filtered.sorted {
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
            signposter.endInterval("Merge_sort", spSort)
            
            return (sorted, msg, !usedBTM)
        }.value
        
        guard generation == refreshGeneration, !Task.isCancelled else {
            logger.debug("Discarding stale refresh results (generation \(generation))")
            return
        }
        
        self.items         = sortedItems
        self.statusMessage = msg
        self.needsFDA      = fda
        self.isLoading     = false
        #if DEBUG
        self.lastRefreshDuration = Date().timeIntervalSince(start)
        #endif
        self.logger.debug("Refresh complete in \(Date().timeIntervalSince(t0))s total.")
    }

    // MARK: — Parsing
    
    static func parseBTM(_ output: String, loadedLabels: Set<String>, systemCache: Set<String>, fallbackLimiter: ConcurrentLimiter, cache: inout [String: URL]) async -> [LoginItem] {
        let fm = FileManager.default
        var results = [LoginItem]()
        let blocks = output.split(separator: "\n\n", omittingEmptySubsequences: true)
        let ws = CharacterSet.whitespaces

        for block in blocks {
            let blockStr = String(block)
            guard blockStr.range(of: "identifier:", options: .caseInsensitive) != nil || blockStr.range(of: "url:", options: .caseInsensitive) != nil else { continue }
            let lines = blockStr.split(separator: "\n", omittingEmptySubsequences: true)

            var rawURL    = ""
            var rawType   = ""
            var disp      = 0
            var ident     = ""
            var devName   = ""
            var devID     = ""

            for line in lines {
                let t = String(line).trimmingCharacters(in: ws)
                
                if t.range(of: "url:", options: [.caseInsensitive, .anchored]) != nil              { rawURL  = Self.val(t, "url:") }
                else if t.range(of: "type:", options: [.caseInsensitive, .anchored]) != nil             { rawType = Self.val(t, "type:") }
                else if t.range(of: "identifier:", options: [.caseInsensitive, .anchored]) != nil       { ident   = Self.val(t, "identifier:") }
                else if t.range(of: "developer name:", options: [.caseInsensitive, .anchored]) != nil   { devName = Self.val(t, "developer name:") }
                else if t.range(of: "developer id:", options: [.caseInsensitive, .anchored]) != nil     { devID   = Self.val(t, "developer id:") }
                else if t.range(of: "team identifier:", options: [.caseInsensitive, .anchored]) != nil  { devID   = Self.val(t, "team identifier:") }
                else if t.range(of: "disposition:", options: [.caseInsensitive, .anchored]) != nil {
                    let tl = t.lowercased()
                    if let hexToken = t.components(separatedBy: "]").last?
                        .trimmingCharacters(in: ws).lowercased(),
                       hexToken.hasPrefix("0x"),
                       let val = Int(hexToken.dropFirst(2), radix: 16) {
                        disp = val
                    } else {
                        if tl.contains("enabled")  && !tl.contains("not enabled")  { disp |= 0x1 }
                        if tl.contains("allowed")  && !tl.contains("not allowed")  { disp |= 0x2 }
                        if tl.contains("visible")  && !tl.contains("not visible")  { disp |= 0x4 }
                    }
                }
            }

            guard !ident.isEmpty || !rawURL.isEmpty else { continue }

            let plistPath = rawURL
                .replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding ?? rawURL.replacingOccurrences(of: "file://", with: "")
            let plistURL: URL? = plistPath.isEmpty ? nil : {
                let u = URL(fileURLWithPath: plistPath)
                return fm.fileExists(atPath: u.path) ? u : nil
            }()

            if ident.isEmpty, let u = plistURL {
                ident = u.deletingPathExtension().lastPathComponent
            }

            let itemType = Self.deriveType(urlPath: plistPath, btmType: rawType)

            var finalDisp = disp
            if disp == 0 && loadedLabels.contains(ident) { finalDisp = 0x3 }
            
            // SYSTEM-domain probe for BTM daemons if disp doesn't say it's enabled
            if (disp & 0x1) == 0 && itemType == .launchDaemon {
                if !systemCache.isEmpty {
                    if systemCache.contains(ident) {
                        finalDisp |= 0x3 // Force enabled/allowed flag
                    }
                } else {
                    let loaded = await fallbackLimiter.execute {
                        let sysOut = await ProcessRunner.shared.run("/bin/launchctl", ["print", "system/\(ident)"], timeout: 2.0).stdout
                        return !sysOut.contains("Bad request") && !sysOut.contains("Could not find")
                    }
                    if loaded { finalDisp |= 0x3 }
                }
            }

            results.append(LoginItem(
                identifier:    ident,
                plistURL:      plistURL,
                type:          itemType,
                developerName: devName,
                developerID:   devID,
                rawDisposition: finalDisp,
                associatedApp: nil
            ))
        }
        return results
    }

    private static func scanPlistDirectories(loadedLabels: Set<String>, systemCache: Set<String>, fallbackLimiter: ConcurrentLimiter) async -> [LoginItem] {
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
                var label = plist.deletingPathExtension().lastPathComponent
                if let data = try? Data(contentsOf: plist),
                   let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let l = root["Label"] as? String {
                    label = l
                }

                let isLoaded = loadedLabels.contains(label)
                var systemLoaded = false
                if type == .launchDaemon {
                    if !systemCache.isEmpty {
                        systemLoaded = systemCache.contains(label)
                    } else {
                        systemLoaded = await fallbackLimiter.execute {
                            let out = await ProcessRunner.shared.run("/bin/launchctl", ["print", "system/\(label)"], timeout: 2.0).stdout
                            return !out.contains("Bad request") && !out.contains("Could not find")
                        }
                    }
                }

                let loaded = isLoaded || systemLoaded
                let disposition = loaded ? 0x3 : 0x2

                results.append(LoginItem(
                    identifier:     label,
                    plistURL:       plist,
                    type:           type,
                    developerName:  "",
                    developerID:    "",
                    rawDisposition: disposition,
                    associatedApp:  nil
                ))
            }
        }
        return results
    }

    // MARK: — Type derivation
    static func deriveType(urlPath: String, btmType: String) -> LoginItemType {
        if urlPath.contains("/LaunchDaemons/")           { return .launchDaemon   }
        if urlPath.contains("/LaunchAgents/")            { return .launchAgent    }
        let t = btmType.lowercased()
        if t == "app" || t == "login-item" || t == "loginitem" { return .loginItem }
        if t == "background" || t == "backgrounditem"    { return .backgroundItem }
        return .unknown
    }

    // MARK: — Find associated .app
    @MainActor
    private static func nsWorkspaceURL(for identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    private static func findAssociatedApp(identifier: String) async -> URL? {
        // 1. O(1) exact match
        if let url = nsWorkspaceURL(for: identifier) {
            return url
        }

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
                    if bid.lowercased() == identifier.lowercased()   {
                        return item
                    }
                    if identifier.lowercased().hasPrefix(bid.lowercased()) {
                        return item
                    }
                }
                let appName = item.deletingPathExtension().lastPathComponent.lowercased()
                if parts.contains(where: { appName.contains($0) }) {
                    return item
                }
            }
        }
        return nil
    }

    private static func val(_ line: String, _ prefix: String) -> String {
        line.replacingOccurrences(of: prefix, with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
    }

    // MARK: — Toggle

    func toggle(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        Task {
            let res = item.isEnabled ? await disable(item, refreshAfter: true) : await enable(item, refreshAfter: true)
            completion(res.success, res.message)
        }
    }

    private func enable(_ item: LoginItem, refreshAfter: Bool = true) async -> (success: Bool, message: String) {
        var success = false

        if let plist = item.plistURL {
            if item.type.requiresAdmin {
                let lines = ["launchctl load -w '\(plist.path.esc)' 2>/dev/null", "echo \"OK\""]
                let res = await ProcessRunner.shared.runAdminScript(lines)
                success = res.success
            } else {
                let domain = "gui/\(self.uid)"
                _ = await ProcessRunner.shared.run("/bin/launchctl", ["enable", "\(domain)/\(item.identifier)"], timeout: 5.0)
                let res = await ProcessRunner.shared.run("/bin/launchctl", ["bootstrap", domain, plist.path], timeout: 5.0)
                success = res.exitCode == 0
                if !success {
                    let res2 = await ProcessRunner.shared.run("/bin/launchctl", ["load", "-w", plist.path], timeout: 5.0)
                    success  = res2.exitCode == 0
                }
            }
        } else {
            let domain = "gui/\(self.uid)"
            let res = await ProcessRunner.shared.run("/bin/launchctl", ["enable", "\(domain)/\(item.identifier)"], timeout: 5.0)
            success = res.exitCode == 0
        }

        if success && refreshAfter { refresh() }
        let msg = success ? "✅ \(item.displayName) enabled" : "❌ Failed to enable \(item.displayName)"
        return (success, msg)
    }

    private func disable(_ item: LoginItem, refreshAfter: Bool = true) async -> (success: Bool, message: String) {
        var success = false

        if let plist = item.plistURL {
            if item.type.requiresAdmin {
                let lines = ["launchctl unload -w '\(plist.path.esc)' 2>/dev/null", "echo \"OK\""]
                let res = await ProcessRunner.shared.runAdminScript(lines)
                success = res.success
            } else {
                let domain = "gui/\(self.uid)"
                _ = await ProcessRunner.shared.run("/bin/launchctl", ["bootout",  "\(domain)/\(item.identifier)"], timeout: 5.0)
                _ = await ProcessRunner.shared.run("/bin/launchctl", ["disable",  "\(domain)/\(item.identifier)"], timeout: 5.0)
                let res = await ProcessRunner.shared.run("/bin/launchctl", ["unload", "-w", plist.path], timeout: 5.0)
                success = res.exitCode == 0 || res.stderr.isEmpty || res.stderr.contains("Could not find specified service")
                if res.exitCode != 0 {
                    self.logger.warning("Unload returned non-zero for \(item.identifier) via \(res.stderr). Assuming gracefully disabled.")
                    success = true
                }
            }
        } else {
            let domain = "gui/\(self.uid)"
            let res = await ProcessRunner.shared.run("/bin/launchctl", ["disable", "\(domain)/\(item.identifier)"], timeout: 5.0)
            success = res.exitCode == 0
        }

        if success && refreshAfter { refresh() }
        let msg = success ? "✅ \(item.displayName) disabled" : "❌ Failed to disable \(item.displayName)"
        return (success, msg)
    }

    // MARK: — Remove
    func remove(_ item: LoginItem, completion: @escaping (Bool, String) -> Void) {
        guard let plist = item.plistURL else {
            completion(false, "❌ No plist file — cannot remove (SMAppService items must be removed by the app itself)")
            return
        }

        Task {
            var success = false

            if item.type.requiresAdmin {
                let e = plist.path.esc
                let lines = [
                    "launchctl bootout system/'\(item.identifier.esc)' 2>/dev/null",
                    "launchctl unload -w '\(e)' 2>/dev/null",
                    "rm -f '\(e)'"
                ]
                let res = await ProcessRunner.shared.runAdminScript(lines)
                success = res.success
            } else {
                let domain = "gui/\(self.uid)"
                _ = await ProcessRunner.shared.run("/bin/launchctl", ["bootout", "\(domain)/\(item.identifier)"], timeout: 5.0)
                _ = await ProcessRunner.shared.run("/bin/launchctl", ["disable", "\(domain)/\(item.identifier)"], timeout: 5.0)
                success = (try? FileManager.default.removeItem(at: plist)) != nil
            }

            if success { self.refresh() }
            
            let msg = success ? "✅ \(item.displayName) removed" : "❌ Failed to remove \(item.displayName)"
            completion(success, msg)
        }
    }

    // MARK: — Helpers
    func revealInFinder(_ item: LoginItem) {
        if let url = item.plistURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealAppInFinder(_ item: LoginItem) {
        if let app = item.associatedApp {
            NSWorkspace.shared.activateFileViewerSelecting([app])
        }
    }

    @MainActor
    func exportItems() {
        let text = items.map { "[\($0.isEnabled ? "ON" : "OFF")] \($0.displayName) (\($0.identifier)) - \($0.type.displayName)" }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacGuard_LoginItems.txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    func exportItemsJSON() -> Data? {
        let exportData = items.map { item in
            [
                "identifier": item.identifier,
                "type": item.type.rawValue,
                "developerName": item.developerName,
                "isEnabled": item.isEnabled,
                "associatedApp": item.associatedApp?.path ?? "",
                "plistPath": item.plistURL?.path ?? ""
            ] as [String : Any]
        }
        
        return try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
    }

    @MainActor
    func showExportJSONPanel() {
        guard let data = exportItemsJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacGuard_LoginItems.json"
        
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    func disableAllNonApple(completion: @escaping (Int) -> Void) {
        let nonAppleItems = items.filter { 
            $0.isEnabled && 
            !$0.developerName.lowercased().contains("apple") &&
            !$0.identifier.lowercased().hasPrefix("com.apple.")
        }
        
        guard !nonAppleItems.isEmpty else { 
            DispatchQueue.main.async { completion(0) }
            return
        }
        
        Task {
            var count = 0
            await withTaskGroup(of: Bool.self) { group in
                var active = 0
                for item in nonAppleItems {
                    if active >= 2 {
                        if await group.next() == true { count += 1 }
                        active -= 1
                    }
                    group.addTask {
                        let res = await self.disable(item, refreshAfter: false)
                        return res.success
                    }
                    active += 1
                }
                for await res in group {
                    if res { count += 1 }
                }
            }
            await MainActor.run { 
                self.refresh()
                completion(count) 
            }
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

// Extension removed in favor of shared String+Escaping.swift
