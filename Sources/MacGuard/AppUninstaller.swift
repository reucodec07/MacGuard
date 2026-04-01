import Foundation
import Security
import Darwin

// MARK: — Types

enum FileDeletability {
    case normal         // ~/Library — no admin
    case needsAdmin     // /Library, /private — admin
    case launchService  // LaunchAgent/Daemon — launchctl unload first
    case sipProtected   // /System, /usr/bin — immovable
}

struct PreflightIssue {
    enum Severity { case blocker, warning, info }
    let severity: Severity
    let icon:     String
    let title:    String
    let detail:   String
}

struct AppBundle: Identifiable, Hashable {
    let id       = UUID()
    let name:              String
    let path:              URL   // as found (may be translocated)
    let realPath:          URL   // canonical path via realpath()
    let bundleID:          String
    let appSize:           Int64
    let isTranslocated:    Bool
    let isOnReadOnlyVolume: Bool
    static func == (l: AppBundle, r: AppBundle) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RelatedFile: Identifiable {
    let id            = UUID()
    let url:            URL
    let size:           Int64
    let source:         String
    let deletability:   FileDeletability
    let isSymlink:      Bool
    let hardLinkCount:  Int
    let isICloudEvicted: Bool

    var label:     String { url.lastPathComponent }
    var sizeLabel: String { RelatedFile.formatSize(size) }

    var requiresAdmin:   Bool { deletability == .needsAdmin || deletability == .launchService }
    var isSIPProtected:  Bool { deletability == .sipProtected }
    var isLaunchService: Bool { deletability == .launchService }
    var canBeDeleted:    Bool { deletability != .sipProtected && !isICloudEvicted }
    // Hard-linked files: deleting one path frees nothing if other links exist
    var spaceSaved:      Int64 { hardLinkCount > 1 ? 0 : size }

    var isDirectory: Bool {
        !isSymlink &&
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
    }

    static func formatSize(_ bytes: Int64) -> String {
        if bytes <= 0            { return "—" }
        if bytes < 1_024         { return "\(bytes) B" }
        if bytes < 1_048_576     { return String(format: "%.1f KB", Double(bytes)/1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes)/1_048_576) }
        return String(format: "%.2f GB", Double(bytes)/1_073_741_824)
    }
}

// MARK: — AppUninstaller

@MainActor
class AppUninstaller: ObservableObject {
    @Published var installedApps:         [AppBundle]      = []
    @Published var relatedFiles:          [RelatedFile]    = []
    @Published var selectedApp:           AppBundle?
    @Published var isScanning             = false
    @Published var isFindingFiles         = false
    @Published var statusMessage          = ""
    @Published var vendorUninstallerURL:  URL?
    @Published var advisoryWarnings:      [String]         = []
    @Published var preflightIssues:       [PreflightIssue] = []

    // Cache for pkgutil --file-info (only populated for sharedLibPaths entries)
    private var sharedFileCache: [String: Bool] = [:]

    private let sharedDirs: Set<String> = [
        "/Library", "/Library/Application Support", "/Library/Caches",
        "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/Group Containers", "/Library/Containers",
        "/Library/PrivilegedHelperTools", "/Library/Extensions",
        "/private", "/private/var", "/private/var/folders",
        "/private/var/db", "/private/var/db/receipts",
        "/usr", "/usr/local", "/System"
    ]

    // Only do pkgutil --file-info cross-reference for these paths (expensive)
    private let sharedLibPaths = ["/Library/Frameworks", "/Library/ColorSync", "/Library/Fonts"]

    private let sipRoots = [
        "/System/", "/usr/bin/", "/usr/sbin/", "/usr/lib/",
        "/bin/", "/sbin/", "/Library/SystemExtensions/"
    ]

    private let userLocations = [
        "Library/Application Support", "Library/Caches",
        "Library/Preferences",         "Library/Logs",
        "Library/Containers",          "Library/Group Containers",
        "Library/Cookies",             "Library/Saved Application State",
        "Library/WebKit",              "Library/HTTPStorages",
        "Library/Application Scripts", "Library/LaunchAgents",
        "Library/Preferences/ByHost",  "Library/PreferencePanes",
        "Library/QuickLook",           "Library/Internet Plug-Ins",
        "Library/Screen Savers",       "Library/Services",
        "Library/Logs/DiagnosticReports",
        "Library/Mail/Bundles",
        "Library/Automator",
        "Library/Fonts",
        "Library/PDF Services",
    ]

    private let systemLocations = [
        "/Library/Application Support",  "/Library/Caches",
        "/Library/Preferences",          "/Library/Logs",
        "/Library/LaunchAgents",         "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Extensions",
        "/Library/PreferencePanes",      "/Library/Fonts",
        "/Library/Logs/DiagnosticReports",
        "/Library/Security/SecurityAgentPlugins",
    ]

    nonisolated private var lsregisterPath: String {
        [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        ].first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    // MARK: — Translocation Resolution
    // SecTranslocateCreateOriginalPathForURL is explicitly unsupported for third-party use.
    // We use realpath() which resolves the bind-mount macOS uses for translocation,
    // with a quarantine xattr parse as a diagnostic fallback.
    nonisolated private func resolveTranslocation(_ url: URL) -> (resolved: URL, isTranslocated: Bool) {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil {
            let resolved = URL(fileURLWithPath: String(cString: buf))
            let isTranslocated = url.path.contains("AppTranslocation") &&
                                 resolved.path != url.path
            return (resolved, isTranslocated)
        }
        // realpath failed — check quarantine xattr to at least flag it
        let isTranslocated = url.path.contains("AppTranslocation")
        return (url, isTranslocated)
    }

    // MARK: — Read-only volume check
    // statfs() is a fast syscall compared to invoking `diskutil info`
    nonisolated private func isOnReadOnlyVolume(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        return (st.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    nonisolated private func lstatInfo(_ url: URL) -> (exists: Bool, isSymlink: Bool, nlink: Int) {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return (false, false, 0) }
        let isLink = (st.st_mode & S_IFMT) == S_IFLNK
        return (true, isLink, Int(st.st_nlink))
    }

    // MARK: — iCloud eviction via Foundation API (no subprocess, no xattr syscall)
    private func isICloudEvicted(_ url: URL) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        else { return false }
        return vals.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    // MARK: — Shared lib cross-reference
    // Only called for files under sharedLibPaths — cached to avoid N subprocess spawns
    private func isSharedByOtherPackages(_ url: URL, appBundleID: String) async -> Bool {
        let path = url.path
        guard sharedLibPaths.contains(where: { path.hasPrefix($0) }) else { return false }
        if let cached = sharedFileCache[path] { return cached }

        let info      = await ProcessRunner.shared.run("/usr/sbin/pkgutil", ["--file-info", path]).stdout
        let pkgLines  = info.components(separatedBy: "\n").filter { $0.contains("pkgid:") }
        var isShared  = pkgLines.count > 1

        if !isShared, let line = pkgLines.first {
            let owner = line.replacingOccurrences(of: "pkgid:", with: "")
                .trimmingCharacters(in: .whitespaces)
            let terms = appBundleID.lowercased().components(separatedBy: ".")
            isShared  = !terms.contains(where: { owner.lowercased().contains($0) })
        }
        await MainActor.run { sharedFileCache[path] = isShared }
        return isShared
    }

    // MARK: — Classification
    private func classify(_ url: URL) -> FileDeletability {
        let path = url.path
        if sipRoots.contains(where: { path.hasPrefix($0) }) { return .sipProtected }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") {
            return .launchService
        }
        if path.hasPrefix("/Library") || path.hasPrefix("/private") ||
           path.hasPrefix("/usr/local") || path.hasPrefix("/var") {
            return .needsAdmin
        }
        return .normal
    }

    // MARK: — Search terms
    // stopWords does NOT include "helper"/"daemon"/"agent" — they identify the app
    nonisolated private func buildTerms(for app: AppBundle) -> Set<String> {
        let stopWords: Set<String> = [
            "com", "app", "the", "inc", "ltd", "org", "net",
            "co", "io", "dev", "mac", "apple", "microsoft", "google", "adobe"
        ]
        let bidParts = app.bundleID
            .components(separatedBy: ".")
            .map    { $0.lowercased() }
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return Set([app.name.lowercased(), app.bundleID.lowercased()] + bidParts)
    }

    // MARK: — Scan installed apps
    func scanApps() {
        guard !isScanning else { return }
        isScanning    = true
        statusMessage = "Scanning applications…"
        sharedFileCache = [:]

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let fm   = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            var apps: [AppBundle] = []

            for dir in ["/Applications", "\(home)/Applications"] {
                let url = URL(fileURLWithPath: dir)
                guard let items = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil) else { continue }
                for item in items where item.pathExtension == "app" {
                    let name = item.deletingPathExtension().lastPathComponent
                    let plist = item.appendingPathComponent("Contents/Info.plist")
                    var bundleID = "com.\(name.lowercased().replacingOccurrences(of: " ", with: "."))"
                    if let dict = NSDictionary(contentsOf: plist),
                       let bid  = dict["CFBundleIdentifier"] as? String { bundleID = bid }

                    // Translocation: realpath() resolves the bind-mount macOS uses
                    let (realPath, isTranslocated) = self.resolveTranslocation(item)

                    // Read-only volume: statfs() — single syscall, no diskutil subprocess
                    let readOnly = self.isOnReadOnlyVolume(item)

                    apps.append(AppBundle(
                        name:               name,
                        path:               item,
                        realPath:           realPath,
                        bundleID:           bundleID,
                        appSize:            self.sizeOf(url: item),
                        isTranslocated:     isTranslocated,
                        isOnReadOnlyVolume: readOnly
                    ))
                }
            }

            let sorted = apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
            await MainActor.run {
                self.installedApps  = sorted
                self.isScanning     = false
                self.statusMessage  = "\(sorted.count) apps found"
            }
        }
    }

    // MARK: — Pre-flight checks
    func runPreflightChecks(for app: AppBundle) async {
        var issues = [PreflightIssue]()
        let fm = FileManager.default

        if app.isOnReadOnlyVolume {
            issues.append(.init(
                severity: .blocker, icon: "externaldrive.badge.exclamationmark",
                title: "\(app.name) is on a read-only volume",
                detail: "Eject the disk image and copy the app to /Applications first."))
        }

        if app.isTranslocated {
            if app.realPath.path == app.path.path {
                issues.append(.init(
                    severity: .blocker, icon: "arrow.triangle.branch",
                    title: "App is Gatekeeper-translocated — real path unresolvable",
                    detail: "Drag the app to /Applications, launch it once to clear quarantine, then uninstall."))
            } else {
                issues.append(.init(
                    severity: .warning, icon: "arrow.triangle.branch",
                    title: "Gatekeeper App Translocation resolved",
                    detail: "Operations will use real path: \(app.realPath.path)"))
            }
        }

        // APFS local snapshots
        let snaps = await ProcessRunner.shared.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).stdout
        if !snaps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .warning, icon: "clock.arrow.circlepath",
                title: "APFS snapshots will retain deleted files until expiry",
                detail: "Force-purge: sudo tmutil deletelocalsnapshots /"))
        }

        // kexts
        let terms = buildTerms(for: app)
        if let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Library/Extensions"),
            includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "kext" {
                let n = item.lastPathComponent.lowercased()
                if terms.contains(where: { n.contains($0) }) {
                    issues.append(.init(
                        severity: .warning, icon: "memorychip",
                        title: "Kernel Extension: \(item.lastPathComponent)",
                        detail: "MacGuard will run kextunload before deletion. A reboot may be needed."))
                }
            }
        }

        // Hard links on large files
        let multiLinked = relatedFiles.filter { $0.hardLinkCount > 1 && $0.size > 1_048_576 }
        if !multiLinked.isEmpty {
            let names = multiLinked.prefix(3).map { $0.label }.joined(separator: ", ")
            issues.append(.init(
                severity: .warning, icon: "link",
                title: "\(multiLinked.count) file(s) are hard-linked — reported space may not be freed",
                detail: "Deleting one path frees nothing until all links are gone: \(names)"))
        }

        await MainActor.run { self.preflightIssues = issues }
    }

    // MARK: — Deep scan
    func findRelatedFiles(for app: AppBundle) {
        isFindingFiles       = true
        relatedFiles         = []
        advisoryWarnings     = []
        vendorUninstallerURL = nil
        statusMessage        = "Running deep scan…"
        sharedFileCache      = [:]

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let fm    = FileManager.default
            let home  = fm.homeDirectoryForCurrentUser.path
            let terms = self.buildTerms(for: app)
            let scanBase = app.realPath   // use real path, not translocated path

            // Vendor uninstaller check
            let vendorInstaller = [
                "Contents/Resources/uninstall.sh", "Contents/Resources/Uninstall.sh",
                "Contents/Resources/uninstaller.sh",
                "Contents/Resources/Uninstaller.app", "Contents/Resources/Uninstall.app",
            ].map { scanBase.appendingPathComponent($0) }
             .first { fm.fileExists(atPath: $0.path) }

            var seen     = Set<String>()
            var found    = [RelatedFile]()
            var warnings = [String]()

            // Cross reference can be awaited inside add
            for q in ["kMDItemCFBundleIdentifier == '\(app.bundleID)'",
                      "kMDItemBundleIdentifier == '\(app.bundleID)'"] {
                let stdout = await ProcessRunner.shared.run("/usr/bin/mdfind", [q]).stdout
                for p in stdout.lines {
                    let u = URL(fileURLWithPath: p)
                    await self.processCandidate(u, source: "Spotlight", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found)
                }
            }
            
            for basePath in ["\(home)/Library", "/Library"] {
                let stdout = await ProcessRunner.shared.run("/usr/bin/mdfind", ["-onlyin", basePath, "-name", app.name]).stdout
                for p in stdout.lines {
                    let u = URL(fileURLWithPath: p)
                    await self.processCandidate(u, source: "Spotlight", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found)
                }
            }

            // Layer 2: pkgutil receipts
            let pkgOut = await ProcessRunner.shared.run("/usr/sbin/pkgutil", ["--pkgs=.*\(terms.sorted().first ?? app.name.lowercased()).*"]).stdout
            let pkgIDs = pkgOut.lines
            for pkgID in pkgIDs {
                let pkgFiles = await ProcessRunner.shared.run("/usr/sbin/pkgutil", ["--files", pkgID]).stdout.lines
                for p in pkgFiles {
                    let u = URL(fileURLWithPath: "/\(p)")
                    if !self.sharedDirs.contains(u.path) {
                        await self.processCandidate(u, source: "Package (\(pkgID))", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found)
                    }
                }
            }

            // Layer 3: directory scan
            for loc in self.userLocations {
                let dir = URL(fileURLWithPath: "\(home)/\(loc)")
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for u in items { await self.processCandidate(u, source: "~/Library", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found) }
                }
            }
            for loc in self.systemLocations {
                let dir = URL(fileURLWithPath: loc)
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for u in items { await self.processCandidate(u, source: "/Library", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found) }
                }
            }

            // Layer 4: /private/var/folders
            let varOut = await ProcessRunner.shared.run("/usr/bin/mdfind", ["-onlyin", "/private/var/folders", app.bundleID]).stdout
            for p in varOut.lines {
                let u = URL(fileURLWithPath: p)
                await self.processCandidate(u, source: "Temp Cache", app: app, terms: terms, seen: &seen, warnings: &warnings, found: &found)
            }

            // Advisory checks
            let netPlist = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/preferences.plist")
            if let prefs = NSDictionary(contentsOf: netPlist),
               let svcs  = prefs["NetworkServices"] as? NSDictionary {
                for (_, val) in svcs {
                    if let svc  = val as? NSDictionary,
                       let name = svc["UserDefinedName"] as? String,
                       terms.contains(where: { name.lowercased().contains($0) }) {
                        warnings.append("🌐 VPN profile '\(name)': System Settings → Network → remove manually, or:\nsudo networksetup -removenetworkservice '\(name)'")
                    }
                }
            }

            warnings.append("🔒 Privacy permissions (Camera/Mic/Full Disk Access) will be reset automatically via tccutil.")

            // SMLoginItems
            let btmDump = await ProcessRunner.shared.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 5.0).stdout
            let btmLower = btmDump.lowercased()
            let btmMatch = terms.contains(where: { btmLower.contains($0) }) ||
                           btmLower.contains(app.bundleID.lowercased())
            if btmMatch {
                warnings.append(
                    "⚙️ Login Item registered for \(app.name) in BTM database.\n" +
                    "MacGuard cannot unregister another app's SMAppService entries. " +
                    "Manual fix: sudo sfltool resetbtm (clears ALL apps — use with care, requires restart).")
            }

            if let dock = NSDictionary(contentsOf: URL(fileURLWithPath: "\(home)/Library/Preferences/com.apple.dock.plist")),
               let pApps = dock["persistent-apps"] as? [[String: Any]] {
                let inDock = pApps.contains { item in
                    if let td = item["tile-data"] as? [String: Any],
                       let fd = td["file-data"]  as? [String: Any],
                       let us = fd["_CFURLString"] as? String {
                        return terms.contains(where: { us.lowercased().contains($0) })
                    }
                    return false
                }
                if inDock { warnings.append("🖥 Dock entry found — right-click the broken icon → Options → Remove from Dock after uninstall.") }
            }

            warnings.append("🔔 Notification Center ghost entry will clear on next login.")

            let deletable  = found.filter { $0.canBeDeleted }
            let sipFiles   = found.filter { $0.isSIPProtected }
            let actualSave = deletable.reduce(app.appSize) { $0 + $1.spaceSaved }
            let adminCnt   = deletable.filter { $0.requiresAdmin   }.count
            let svcCnt     = deletable.filter { $0.isLaunchService }.count

            var msg = "\(found.count) files · \(RelatedFile.formatSize(actualSave)) to free"
            if sipFiles.count > 0 { msg += " · \(sipFiles.count) SIP-protected" }
            if adminCnt > 0       { msg += " · \(adminCnt) need admin" }
            if svcCnt > 0         { msg += " · \(svcCnt) services to unload" }

            let finalMsg = msg 
            let finalWarnings = warnings
            let finalSorted = found.sorted {
                if $0.isSIPProtected != $1.isSIPProtected { return !$0.isSIPProtected }
                return $0.size > $1.size
            }

            await MainActor.run {
                self.relatedFiles        = finalSorted
                self.isFindingFiles      = false
                self.statusMessage       = finalMsg
                self.vendorUninstallerURL = vendorInstaller
                self.advisoryWarnings    = finalWarnings
            }
            
            await self.runPreflightChecks(for: app)
        }
    }

    private func processCandidate(_ url: URL, source: String, app: AppBundle, terms: Set<String>, seen: inout Set<String>, warnings: inout [String], found: inout [RelatedFile]) async {
        let path = url.path
        let scanBase = app.realPath
        let lastName = url.lastPathComponent.lowercased()

        let (exists, isLink, nlink) = self.lstatInfo(url)
        guard exists,
              !seen.contains(path),
              !path.hasPrefix(scanBase.path),
              !self.sharedDirs.contains(path),
              terms.contains(where: { lastName.contains($0) }) else { return }

        // Needs await
        if await self.isSharedByOtherPackages(url, appBundleID: app.bundleID) {
            warnings.append("⚠️ Shared lib skipped (other apps use it): \(url.lastPathComponent)")
            return
        }

        let isCloud = self.isICloudEvicted(url)
        if isCloud {
            warnings.append("☁️ iCloud evicted placeholder: \(url.lastPathComponent) — delete from iCloud.com or re-download first")
        }

        seen.insert(path)
        
        let fileItemSize = self.sizeOf(url: url)
        if fileItemSize > 1_073_741_824 {
            warnings.append("ℹ️ \(url.lastPathComponent) is over 1 GB — size computation was truncated.")
        }
        
        found.append(RelatedFile(
            url:             url,
            size:            fileItemSize,
            source:          source,
            deletability:    self.classify(url),
            isSymlink:       isLink,
            hardLinkCount:   nlink,
            isICloudEvicted: isCloud
        ))
    }

    // MARK: — Uninstall
    func uninstall(app: AppBundle, completion: @escaping (Bool, String) -> Void) {
        let appPath = app.realPath

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default

            let deletable     = await MainActor.run { self.relatedFiles.filter { $0.canBeDeleted } }
            var normalPaths   = deletable.filter { !$0.requiresAdmin }.map { $0.url.path }
            var adminPaths    = deletable.filter {  $0.requiresAdmin }.map { $0.url.path }
            let launchSvcIDs  = deletable.filter { $0.isLaunchService }
                .compactMap { f -> String? in
                    let n = f.url.deletingPathExtension().lastPathComponent
                    return n.isEmpty ? nil : n
                }

            appPath.path.hasPrefix("/Applications")
                ? adminPaths.insert(appPath.path, at: 0)
                : normalPaths.insert(appPath.path, at: 0)

            if !self.lsregisterPath.isEmpty {
                await ProcessRunner.shared.run(self.lsregisterPath, ["-u", appPath.path])
            }

            var failedNormal: [String] = []
            for path in normalPaths {
                let url = URL(fileURLWithPath: path)
                let (exists, isLink, _) = self.lstatInfo(url)
                guard exists else { continue }

                await self.killHolders(path)
                await ProcessRunner.shared.run("/usr/bin/chflags", ["-R", "nouchg", path])
                await ProcessRunner.shared.run("/bin/chmod",       ["-RN",           path])
                await ProcessRunner.shared.run("/usr/bin/xattr",   ["-cr",           path])
                do {
                    if isLink { try fm.removeItem(at: url) }
                    else      { try fm.removeItem(atPath: path) }
                } catch {
                    failedNormal.append(url.lastPathComponent)
                }
            }

            var lines = [
                "#!/bin/bash",
                "FAIL=''",
                "UID_NOW=$(id -u)",
                "",
                "# Phase 1: UTI deregistration",
            ]
            if !self.lsregisterPath.isEmpty {
                lines.append("'\(self.lsregisterPath.esc)' -u '\(appPath.path.esc)' 2>/dev/null")
            }
            
            // Replaced pgrep -i with exact match kill (-x) or exact bundle pattern
            lines += [
                "",
                "# Phase 2: Kill all app processes",
                "PIDS=$( { pgrep -x '\(app.name.esc)'; pgrep -f '\(app.bundleID.esc)'; } 2>/dev/null | sort -u)",
                "[ -n \"$PIDS\" ] && kill -9 $PIDS 2>/dev/null && sleep 0.5",
                "",
                "# Phase 3: Unload LaunchAgents/Daemons BEFORE deleting their plists",
            ]
            for svcID in launchSvcIDs {
                let e = svcID.esc
                lines += [
                    "launchctl bootout system/'\(e)' 2>/dev/null",
                    "launchctl bootout user/$UID_NOW/'\(e)' 2>/dev/null",
                    "launchctl unload -w '/Library/LaunchDaemons/\(e).plist' 2>/dev/null",
                    "launchctl unload -w '/Library/LaunchAgents/\(e).plist' 2>/dev/null",
                    "launchctl remove '\(e)' 2>/dev/null",
                ]
            }

            lines += [
                "",
                "# Phase 4: Batch-kill all file holders",
                "KILL_PATHS=("
            ]
            for path in adminPaths { lines.append("  '\(path.esc)'") }
            lines += [
                ")",
                "[ ${#KILL_PATHS[@]} -gt 0 ] && FHPIDS=$(lsof -t \"${KILL_PATHS[@]}\" 2>/dev/null | sort -u)",
                "[ -n \"$FHPIDS\" ] && kill -9 $FHPIDS 2>/dev/null && sleep 0.5",
                ""
            ]

            for path in adminPaths {
                let e      = path.esc
                let isLink = self.lstatInfo(URL(fileURLWithPath: path)).isSymlink
                let rmCmd  = isLink ? "rm -f" : "rm -rf"
                let isKext = path.hasSuffix(".kext")
                var block  = [
                    "if [ -e '\(e)' ] || [ -L '\(e)' ]; then",
                    "  chflags -R nouchg '\(e)' 2>/dev/null",
                    "  chmod -RN '\(e)' 2>/dev/null",
                    "  xattr -cr '\(e)' 2>/dev/null",
                ]
                if isKext {
                    block += [
                        "  kextunload '\(e)' 2>/dev/null",
                        "  sleep 0.5",
                    ]
                }
                block += [
                    "  \(rmCmd) '\(e)' 2>/dev/null && echo \"OK\" || FAIL=\"$FAIL|'\(e)'\"",
                    "fi",
                    ""
                ]
                lines += block
            }

            lines += [
                "# Phase 5: System registrations cleanup",
                "pkgutil --forget '\(app.bundleID.esc)' 2>/dev/null",
                "tccutil reset All '\(app.bundleID.esc)' 2>/dev/null",
            ]
            if !self.lsregisterPath.isEmpty {
                lines.append(
                    "'\(self.lsregisterPath.esc)' -kill -r -domain local -domain system -domain user 2>/dev/null &")
            }
            lines += ["", "printf 'FAILURES:%s\\n' \"$FAIL\""]

            var failedAdmin: [String] = []
            if !adminPaths.isEmpty {
                let res = await ProcessRunner.shared.runAdminScript(lines)
                if !res.success {
                    failedAdmin = adminPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                } else if let failLine = res.output.components(separatedBy: "\n").first(where: { $0.hasPrefix("FAILURES:") }) {
                    failedAdmin = failLine
                        .replacingOccurrences(of: "FAILURES:", with: "")
                        .components(separatedBy: "|")
                        .filter { !$0.isEmpty }
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                }
            }

            let allFailed = failedNormal + failedAdmin
            let appGone   = !fm.fileExists(atPath: appPath.path)
            
            // Using MainActor to safely interact with relatedFiles array
            await MainActor.run {
                let sipCount  = self.relatedFiles.filter { $0.isSIPProtected }.count
                let warnCount = self.advisoryWarnings.count
                if appGone {
                    self.installedApps.removeAll { $0.id == app.id }
                    self.relatedFiles  = []
                    self.selectedApp   = nil
                    self.statusMessage = ""
                }
                if allFailed.isEmpty && appGone {
                    var notes: [String] = []
                    if sipCount  > 0 { notes.append("🛡 \(sipCount) SIP-protected file(s) skipped — harmless.") }
                    if warnCount > 0 { notes.append("ℹ️ Check the advisory panel for manual steps.") }
                    completion(true,
                        "✅ \(app.name) completely removed" +
                        (notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n")))
                } else if !appGone {
                    completion(false,
                        "❌ \(app.name).app could not be deleted.\n\n" +
                        "Force Kill '\(app.name)' in Activity Monitor then try again.")
                } else {
                    let names = Array(Set(allFailed)).prefix(6).joined(separator: "\n• ")
                    completion(false,
                        "⚠️ \(app.name) removed but \(allFailed.count) file(s) failed:\n\n• \(names)")
                }
            }
        }
    }

    // MARK: — Helpers
    func totalSizeToFree(for app: AppBundle) -> String {
        RelatedFile.formatSize(
            relatedFiles.filter { $0.canBeDeleted }.reduce(app.appSize) { $0 + $1.spaceSaved })
    }
    func adminFileCount()  -> Int { relatedFiles.filter { $0.requiresAdmin   }.count }
    func sipFileCount()    -> Int { relatedFiles.filter { $0.isSIPProtected  }.count }
    func launchSvcCount()  -> Int { relatedFiles.filter { $0.isLaunchService }.count }
    func hardLinkedCount() -> Int { relatedFiles.filter { $0.hardLinkCount > 1 }.count }
    func iCloudCount()     -> Int { relatedFiles.filter { $0.isICloudEvicted }.count }

    private func killHolders(_ path: String) async {
        let pids = await ProcessRunner.shared.run("/usr/bin/lsof", ["-t", path]).stdout.lines.compactMap { Int32($0) }
        pids.forEach { Darwin.kill($0, SIGKILL) }
        if !pids.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    // sizeOf WITHOUT .skipsHiddenFiles — .DS_Store and ._* files are real disk usage
    nonisolated private func sizeOf(url: URL) -> Int64 {
        let (_, isLink, _) = lstatInfo(url)
        if isLink {
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int64 ?? 0
        }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]  // no options = include hidden
        ) else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int64 ?? 0
        }
        let limit: Int64 = 1_073_741_824 // 1GB bailout constraint for UI scanning speed
        for case let f as URL in enumerator {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if total > limit { return total }
        }
        return total
    }
}

private extension String {
    var lines: [String] {
        components(separatedBy: "\n")
            .map    { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
