import Foundation
import AppKit

// MARK: — Safety classification

enum CleanupCategory: String, CaseIterable {
    case cache       = "Cache"
    case log         = "Log"
    case temp        = "Temporary"
    case download    = "Download"
    case largeMedia  = "Large Media"
    case appData     = "App Data"
    case userFile    = "User File"
    case unknown     = "Other"
}

enum SafetyLevel: Int, Comparable {
    case safe     = 0   // caches, logs, temp — regenerated automatically
    case caution  = 1   // downloads, large files — user created but may be wanted
    case review   = 2   // app data, preferences — could break things

    static func < (l: SafetyLevel, r: SafetyLevel) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .safe:    return "Safe to remove"
        case .caution: return "Review first"
        case .review:  return "Be careful"
        }
    }

    var icon: String {
        switch self {
        case .safe:    return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .review:  return "xmark.shield.fill"
        }
    }

    var color: String {   // returned as string so View layer picks the Color
        switch self {
        case .safe:    return "green"
        case .caution: return "orange"
        case .review:  return "red"
        }
    }
}

// MARK: — Classified disk item

struct CleanupItem: Identifiable, Hashable {
    let id              = UUID()
    let url:              URL
    let name:             String
    let size:             Int64
    let category:         CleanupCategory
    let safety:           SafetyLevel
    let reason:           String
    let confidence:       Int       // 0–100: certainty this is safe to delete
    let lastAccessedDays: Int?      // nil = unknown, 0 = today, 730 = 2 years ago

    var sizeLabel: String { DiskItem.formatSize(size) }

    // Only safe + confidence ≥ 90 items are offered for permanent delete
    var canPermanentlyDelete: Bool {
        safety == .safe && confidence >= 90
    }

    var confidenceLabel: String {
        switch confidence {
        case 90...100: return "High confidence"
        case 70...89:  return "Moderate"
        case 50...69:  return "Low confidence"
        default:       return "Uncertain"
        }
    }

    var lastAccessedLabel: String {
        guard let days = lastAccessedDays else { return "Unknown" }
        switch days {
        case 0:        return "Today"
        case 1:        return "Yesterday"
        case 2...6:    return "\(days) days ago"
        case 7...29:   return "\(days / 7) week\(days / 7 == 1 ? "" : "s") ago"
        case 30...364: return "\(days / 30) month\(days / 30 == 1 ? "" : "s") ago"
        default:       return "\(days / 365) year\(days / 365 == 1 ? "" : "s") ago"
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: CleanupItem, r: CleanupItem) -> Bool { l.id == r.id }
}

// MARK: — CleanupEngine

class CleanupEngine: ObservableObject {
    @Published var suggestions:   [CleanupItem] = []
    @Published var staged:        [CleanupItem] = []
    @Published var isAnalysing    = false
    @Published var isAIEnhancing  = false   // second phase — AI review in progress
    @Published var aiSummary:     String?   // Haiku's one-line overview
    @Published var isDeleting     = false
    @Published var deleteResult:  String?

    private let ai = AICleanupAnalyser()

    // MARK: — Analyse a scanned folder tree for cleanup opportunities
    // Phase 1: rule engine (instant)
    // Phase 2: Haiku enhancement (async, ~2s, falls back silently on failure)

    func analyse(rootURL: URL, allItems: [DiskItem], apiKey: String? = nil) {
        isAnalysing   = true
        isAIEnhancing = false
        aiSummary     = nil
        suggestions   = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var found = [CleanupItem]()

            for item in allItems where !item.isPending && item.size > 0 {
                if let classified = self.classify(item, rootURL: rootURL) {
                    found.append(classified)
                }
            }

            // Targeted scan for known junk patterns
            let home = FileManager.default.homeDirectoryForCurrentUser
            let junkScans: [(URL, CleanupCategory, SafetyLevel, String)] = [
                (home.appendingPathComponent("Library/Caches"),
                 .cache, .safe,
                 "App caches — regenerated automatically on next launch"),
                (home.appendingPathComponent("Library/Logs"),
                 .log, .safe,
                 "Application logs — safe to clear, apps recreate them"),
                (URL(fileURLWithPath: "/Library/Logs"),
                 .log, .safe,
                 "System logs — safe to clear"),
                (home.appendingPathComponent("Library/Application Support/CrashReporter"),
                 .log, .safe,
                 "Crash reports — no longer needed"),
                (home.appendingPathComponent("Library/Containers"),
                 .cache, .caution,
                 "App container data — includes caches and app data"),
            ]

            for (dir, category, safety, reason) in junkScans {
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: []
                )) ?? []

                for child in children {
                    let alreadyFound = found.contains { $0.url.path == child.path }
                    guard !alreadyFound else { continue }
                    let size = self.quickSize(child)
                    guard size > 1_048_576 else { continue }
                    let accessed = self.lastAccessedDays(child)
                    let conf = self.computeConfidence(
                        path: child.path,
                        name: child.lastPathComponent.lowercased(),
                        ext:  child.pathExtension.lowercased(),
                        category: category, safety: safety,
                        lastAccessed: accessed
                    )
                    found.append(CleanupItem(
                        url: child, name: child.lastPathComponent,
                        size: size, category: category,
                        safety: safety, reason: reason,
                        confidence: conf,
                        lastAccessedDays: accessed
                    ))
                }
            }

            let sorted = found.sorted {
                if $0.safety != $1.safety { return $0.safety < $1.safety }
                return $0.size > $1.size
            }
            let autoStaged = sorted.filter { $0.safety == .safe }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Phase 1 complete — show results immediately
                self.suggestions  = sorted
                self.staged       = autoStaged
                self.isAnalysing  = false

                // Phase 2 — AI enhancement if key provided
                if let key = apiKey, !key.isEmpty {

                    // Precision filter — only send items where rule engine
                    // genuinely cannot make the right call alone.
                    let ambiguous = sorted.filter { item in
                        let path = item.url.path
                        let name = item.name.lowercased()
                        let ext  = item.url.pathExtension.lowercased()

                        // 1. Rule engine gave up — unknown category
                        if item.category == .unknown { return true }

                        // 2. App containers — Haiku judges active vs abandoned.
                        //    This is where AI adds the most value (confirmed by logs).
                        if path.contains("/Containers/") ||
                           path.contains("/Group Containers/") { return true }

                        // 3. Large uncertain items >50MB — worth the API cost.
                        //    Small uncertain files are not.
                        if item.safety != .safe && item.size > 52_428_800 { return true }

                        // 4. Ambiguous filenames on non-safe items —
                        //    installers, old projects, copies the rule engine
                        //    can flag but not contextually evaluate.
                        let ambiguousExts  = ["xip","pkg","dmg"]
                        let ambiguousNames = ["backup","archive","old","copy",
                                              "version","install","setup"]
                        if item.safety != .safe && (
                            ambiguousExts.contains(ext) ||
                            ambiguousNames.contains(where: { name.contains($0) })
                        ) { return true }

                        // Safe items and well-understood patterns — skip AI
                        return false
                    }

                    // Nothing ambiguous — skip the API call entirely
                    guard !ambiguous.isEmpty else {
                        self.isAIEnhancing = false
                        return
                    }

                    self.isAIEnhancing = true
                    self.ai.enhance(
                        items:   ambiguous,
                        rootURL: rootURL,
                        apiKey:  key
                    ) { [weak self] enhanced, summary in
                        guard let self else { return }
                        // Merge AI-enhanced ambiguous items back with
                        // the untouched safe items from the rule engine
                        let ambiguousPaths = Set(ambiguous.map { $0.url.path })
                        let untouched = sorted.filter { !ambiguousPaths.contains($0.url.path) }
                        let merged = (untouched + enhanced).sorted {
                            if $0.safety != $1.safety { return $0.safety < $1.safety }
                            return $0.size > $1.size
                        }
                        let newAutoStaged = merged.filter { $0.safety == .safe }
                        self.suggestions   = merged
                        self.staged        = newAutoStaged
                        self.aiSummary     = summary
                        self.isAIEnhancing = false
                    }
                }
            }
        }
    }

    // MARK: — Classify a DiskItem

    // MARK: — Last accessed date helper
    // Returns how many days ago the file/folder was last accessed.
    // Uses contentAccessDateKey — a single syscall, no subprocess.
    private func lastAccessedDays(_ url: URL) -> Int? {
        guard let vals = try? url.resourceValues(forKeys: [.contentAccessDateKey]),
              let date = vals.contentAccessDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return max(0, days)
    }

    // MARK: — Confidence scoring
    // Confidence = how certain we are this item is safe to permanently delete.
    // Built from three signals: path certainty (primary), last-accessed recency,
    // and filename risk patterns. Each signal contributes independently.
    private func computeConfidence(
        path: String, name: String, ext: String,
        category: CleanupCategory, safety: SafetyLevel,
        lastAccessed: Int?
    ) -> Int {
        var score = 0

        // Signal 1: Path certainty (50 pts max)
        // Hardcoded macOS conventions are highly reliable
        switch category {
        case .cache:
            if path.contains("/Library/Caches/") { score += 50 }
            else if path.contains("/Caches/") || path.contains("/Cache/") { score += 45 }
            else if path.contains("node_modules") || path.contains(".gradle") { score += 42 }
            else { score += 35 }
        case .log:
            score += path.contains("/Library/Logs/") ? 48 : 40
        case .temp:
            score += (ext == "tmp" || path.contains("/tmp/")) ? 50 : 38
        case .download:
            score += 30   // user created — inherently less certain
        case .largeMedia:
            score += 20   // could be irreplaceable
        case .appData:
            score += 10   // highest risk
        case .userFile:
            score += 15
        case .unknown:
            score += 10
        }

        // Signal 2: Last accessed recency (30 pts max)
        // Older = safer. Not accessed in 2+ years = very likely safe.
        if let days = lastAccessed {
            switch days {
            case 730...:   score += 30  // 2+ years — almost certainly stale
            case 365..<730: score += 25  // 1–2 years
            case 180..<365: score += 18  // 6–12 months
            case 90..<180:  score += 10  // 3–6 months
            case 30..<90:   score += 5   // 1–3 months
            case 7..<30:    score += 2   // last month
            default:        score += 0   // accessed this week — penalise nothing, add nothing
            }
        } else {
            score += 10  // unknown — assume moderate staleness
        }

        // Signal 3: Filename risk patterns (–20 pts for risky names)
        // Names that suggest important user content reduce confidence
        let riskyPatterns = [
            "backup", "archive", "final", "important", "original",
            "project", "invoice", "receipt", "passport", "contract",
            "license", "certificate", "private", "secret", "password"
        ]
        if riskyPatterns.contains(where: { name.contains($0) }) {
            score -= 20
        }

        // Signal 4: Safety level modifier
        // Review items can never reach 90+ regardless of other signals
        if safety == .review  { score = min(score, 60) }
        if safety == .caution { score = min(score, 79) }

        // Signal 5: Active system process penalty
        // Containers owned by a running process should never be auto-staged.
        // Check if the bundle ID (folder name) matches a running process.
        if path.contains("/Containers/") {
            let bundleID = URL(fileURLWithPath: path).lastPathComponent
            let check = Process()
            check.executableURL  = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments      = ["-f", bundleID]
            let pipe = Pipe()
            check.standardOutput = pipe
            check.standardError  = FileHandle.nullDevice
            try? check.run(); check.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Process is actively running — cap confidence so it never auto-stages
                score = min(score, 45)
            }
        }

        return max(0, min(100, score))
    }

    private func classify(_ item: DiskItem, rootURL: URL) -> CleanupItem? {
        let path  = item.url.path
        let name  = item.name.lowercased()
        let ext   = item.url.pathExtension.lowercased()
        let home  = FileManager.default.homeDirectoryForCurrentUser.path
        let accessed = lastAccessedDays(item.url)

        func makeItem(
            category: CleanupCategory,
            safety: SafetyLevel,
            reason: String
        ) -> CleanupItem {
            let conf = computeConfidence(
                path: path, name: name, ext: ext,
                category: category, safety: safety,
                lastAccessed: accessed
            )
            return CleanupItem(
                url: item.url, name: item.name, size: item.size,
                category: category, safety: safety,
                reason: reason,
                confidence: conf,
                lastAccessedDays: accessed
            )
        }

        // ── Cache paths ─────────────────────────────────────
        let cachePaths = [
            "/Library/Caches/", "/Caches/", "/Cache/",
            "/tmp/", "/private/tmp/",
            "/.gradle/caches/", "/.npm/", "/.yarn/cache", "/node_modules/",
        ]
        if cachePaths.contains(where: { path.contains($0) })
            || name.hasSuffix(".cache") || name == ".ds_store" {
            return makeItem(
                category: .cache, safety: .safe,
                reason: "Cache — regenerated automatically on next app launch"
            )
        }

        // ── Log files ────────────────────────────────────────
        if path.contains("/Logs/") || ext == "log" || name.hasSuffix(".log") {
            return makeItem(
                category: .log, safety: .safe,
                reason: "Log file — apps recreate these automatically"
            )
        }

        // ── Temp files ───────────────────────────────────────
        if ext == "tmp" || name.hasPrefix("tmp") || name.hasPrefix("temp") {
            return makeItem(
                category: .temp, safety: .safe,
                reason: "Temporary file — no longer needed"
            )
        }

        // ── Large downloads ──────────────────────────────────
        let downloadPath = "\(home)/Downloads"
        if path.hasPrefix(downloadPath) && item.size > 10_000_000 {
            return makeItem(
                category: .download, safety: .caution,
                reason: "Large download — check you no longer need this"
            )
        }

        // ── Large media / archives ────────────────────────────
        let mediaExts: Set<String> = ["mov","mp4","avi","mkv","m4v","dmg","iso","zip","tar","gz"]
        if mediaExts.contains(ext) && item.size > 100_000_000 {
            return makeItem(
                category: .largeMedia, safety: .caution,
                reason: "Large \(ext.uppercased()) (\(item.sizeLabel)) — verify you have another copy"
            )
        }

        // ── App data ─────────────────────────────────────────
        if path.contains("/Application Support/") && item.size > 50_000_000 {
            return makeItem(
                category: .appData, safety: .review,
                reason: "App data — may contain saved state or settings"
            )
        }

        // ── Very large unknowns ───────────────────────────────
        if item.size > 524_288_000 {
            return makeItem(
                category: .unknown, safety: .caution,
                reason: "Very large item (\(item.sizeLabel)) — worth reviewing"
            )
        }

        return nil
    }

    // MARK: — Staging

    func stage(_ item: CleanupItem) {
        guard !staged.contains(item) else { return }
        staged.append(item)
    }

    func unstage(_ item: CleanupItem) {
        staged.removeAll { $0.id == item.id }
    }

    func toggleStage(_ item: CleanupItem) {
        staged.contains(item) ? unstage(item) : stage(item)
    }

    func stageAll(safety: SafetyLevel) {
        let toAdd = suggestions.filter { $0.safety == safety && !staged.contains($0) }
        staged.append(contentsOf: toAdd)
    }

    func unstageAll() { staged = [] }

    // MARK: — Computed staging stats

    var stagedSize:        Int64  { staged.reduce(0) { $0 + $1.size } }
    var stagedSizeLabel:   String { DiskItem.formatSize(stagedSize) }
    var stagedSafeCount:   Int    { staged.filter { $0.safety == .safe    }.count }
    var stagedCautionCount: Int   { staged.filter { $0.safety == .caution }.count }
    var stagedReviewCount: Int    { staged.filter { $0.safety == .review  }.count }

    // Worst safety level in the current staged set
    var overallSafety: SafetyLevel {
        if stagedReviewCount  > 0 { return .review  }
        if stagedCautionCount > 0 { return .caution }
        return .safe
    }

    // MARK: — Computed: items eligible for permanent delete
    var permanentDeleteEligible: [CleanupItem] {
        staged.filter { $0.canPermanentlyDelete }
    }
    var permanentDeleteSize: Int64 {
        permanentDeleteEligible.reduce(0) { $0 + $1.size }
    }
    var permanentDeleteSizeLabel: String { DiskItem.formatSize(permanentDeleteSize) }

    // MARK: — Execute: permanent delete (only high-confidence safe items)
    // Uses FileManager.removeItem — irreversible. Only called after the
    // two-step "type DELETE" confirmation in the UI.
    func permanentDelete(completion: @escaping (Int, Int64, String?) -> Void) {
        let eligible = permanentDeleteEligible
        guard !eligible.isEmpty else { return }
        isDeleting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deletedCount: Int   = 0
            var freedBytes:   Int64 = 0
            var failures:     [String] = []

            for item in eligible {
                // Final safety check immediately before deletion —
                // re-verify the item still matches safe criteria
                guard item.canPermanentlyDelete else { continue }
                do {
                    try FileManager.default.removeItem(at: item.url)
                    deletedCount += 1
                    freedBytes   += item.size
                } catch {
                    failures.append(item.name)
                }
            }

            let failMsg = failures.isEmpty ? nil
                : "\(failures.count) item(s) could not be deleted"

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let failedNames = Set(failures)
                self.staged      = self.staged.filter { failedNames.contains($0.name) }
                self.suggestions = self.suggestions.filter { s in
                    !eligible.contains(where: { $0.id == s.id && !failedNames.contains(s.name) })
                }
                self.isDeleting  = false
                completion(deletedCount, freedBytes, failMsg)
            }
        }
    }

    // MARK: — Execute: move to Trash (never permanent delete)

    func moveToTrash(completion: @escaping (Int, Int64, String?) -> Void) {
        guard !staged.isEmpty else { return }
        isDeleting   = true
        deleteResult = nil

        let toDelete = staged

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deletedCount: Int  = 0
            var freedBytes:   Int64 = 0
            var failures:     [String] = []

            for item in toDelete {
                // Verify item still exists before attempting trash
                var _st = Darwin.stat()
                let exists = FileManager.default.fileExists(atPath: item.url.path) ||
                             (lstat(item.url.path, &_st) == 0 && (_st.st_mode & S_IFMT) == S_IFLNK)
                guard exists else {
                    // Item already gone — count as success
                    deletedCount += 1
                    continue
                }

                var trashedURL: NSURL?
                do {
                    try FileManager.default.trashItem(
                        at: item.url,
                        resultingItemURL: &trashedURL
                    )
                    deletedCount += 1
                    freedBytes   += item.size
                } catch {
                    // Strip immutable flag + xattrs
                    let path = item.url.path
                    for (exe, args) in [
                        ("/usr/bin/chflags", ["-R", "nouchg", path]),
                        ("/usr/bin/xattr",   ["-cr",          path])
                    ] {
                        let t = Process()
                        t.executableURL  = URL(fileURLWithPath: exe)
                        t.arguments      = args
                        t.standardOutput = FileHandle.nullDevice
                        t.standardError  = FileHandle.nullDevice
                        try? t.run(); t.waitUntilExit()
                    }
                    // For Container folders, kill the owning process first.
                    // The bundle ID is the folder name (e.g. com.apple.mediaanalysisd)
                    if path.contains("/Containers/") {
                        let bundleID = item.url.lastPathComponent
                        let killer = Process()
                        killer.executableURL  = URL(fileURLWithPath: "/usr/bin/pkill")
                        killer.arguments      = ["-f", bundleID]
                        killer.standardOutput = FileHandle.nullDevice
                        killer.standardError  = FileHandle.nullDevice
                        try? killer.run(); killer.waitUntilExit()
                        Thread.sleep(forTimeInterval: 0.5)
                    }

                    var retryURL: NSURL?
                    do {
                        try FileManager.default.trashItem(
                            at: item.url,
                            resultingItemURL: &retryURL
                        )
                        deletedCount += 1
                        freedBytes   += item.size
                    } catch let retryError {
                        failures.append("\(item.name) (\(retryError.localizedDescription))")
                    }
                }
            }

            let failMsg = failures.isEmpty
                ? nil
                : "\(failures.count) item(s) could not be moved to Trash:\n\(failures.prefix(3).joined(separator: "\n"))"

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Remove successfully trashed items from staged
                let failedNames = Set(failures)
                self.staged     = self.staged.filter { failedNames.contains($0.name) }
                self.suggestions = self.suggestions.filter { s in
                    !toDelete.contains(where: { $0.id == s.id && !failedNames.contains(s.name) })
                }
                self.isDeleting  = false
                completion(deletedCount, freedBytes, failMsg)
            }
        }
    }

    // MARK: — Helpers

    private func quickSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int64 ?? 0
        }
        for case let f as URL in enumerator {
            total += Int64(
                (try? f.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize ?? 0
            )
        }
        return total
    }
}