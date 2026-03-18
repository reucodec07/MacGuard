import Foundation
import SwiftUI
import Combine

// MARK: — Score types

struct StartupScore {
    enum Source {
        case heuristic   // plist analysis only — process not currently running
        case live        // heuristic + live CPU/RAM from running process

        var label: String {
            switch self {
            case .heuristic: return "Estimated"
            case .live:      return "Live"
            }
        }
        var icon: String {
            switch self {
            case .heuristic: return "chart.bar"
            case .live:      return "waveform"
            }
        }
    }

    enum Level: String, CaseIterable, Comparable {
        case low      = "Low"
        case medium   = "Medium"
        case high     = "High"
        case critical = "Critical"

        var color: Color {
            switch self {
            case .low:      return .green
            case .medium:   return .yellow
            case .high:     return .orange
            case .critical: return .red
            }
        }
        var icon: String {
            switch self {
            case .low:      return "checkmark.circle.fill"
            case .medium:   return "exclamationmark.circle.fill"
            case .high:     return "exclamationmark.triangle.fill"
            case .critical: return "xmark.octagon.fill"
            }
        }
        private var order: Int {
            switch self {
            case .low: return 0; case .medium: return 1
            case .high: return 2; case .critical: return 3
            }
        }
        static func < (l: Level, r: Level) -> Bool { l.order < r.order }
    }

    let numeric:    Int         // 0–100
    let level:      Level
    let source:     Source
    let factors:    [String]    // human-readable breakdown shown in expanded row
    let liveCPU:    Double?     // nil when process is not running
    let liveMemMB:  Double?     // nil when process is not running
    let isRunning:  Bool
}

struct ScoredLoginItem: Identifiable {
    let id    = UUID()
    let item:   LoginItem
    var score:  StartupScore
}

// MARK: — StartupScorer
// Scores are computed on demand from:
//   1. Plist key analysis (always available, instant)
//   2. Live CPU/RAM from ProcessMonitor (when the process is running right now)
// No persistence, no sample accumulation — scores update every poll cycle.

class StartupScorer: ObservableObject {
    @Published var scoredItems: [ScoredLoginItem] = []

    // MARK: — Score all items against current live process snapshot
    // processes: the current snapshot from ProcessMonitor.processes (all processes, not just top N)
    func scoreAll(_ items: [LoginItem], liveProcesses: [AppProcess]) {
        let scored = items
            .map { item -> ScoredLoginItem in
                let liveProcess = findProcess(for: item, in: liveProcesses)
                return ScoredLoginItem(item: item, score: score(item, live: liveProcess))
            }
            .sorted { $0.score.numeric > $1.score.numeric }

        DispatchQueue.main.async { self.scoredItems = scored }
    }

    // MARK: — Score a single item
    func score(_ item: LoginItem, live: AppProcess?) -> StartupScore {
        let h = heuristicScore(item)

        guard let process = live else { return h }

        // Process is running — blend heuristic base with live CPU+RAM
        // Live CPU: 0% → +0, 100% → +40 pts (capped — CPU spikes shouldn't dominate)
        // Live RAM: 0 MB → +0, 500 MB → +20 pts
        let cpuPts = min(40.0, process.cpuPercent * 0.4)
        let memPts = min(20.0, process.memoryMB * 0.04)

        // Weighted blend: 60% heuristic structural factors + 40% live behaviour
        let blended = Int(Double(h.numeric) * 0.6 + (cpuPts + memPts) * 1.0)
        let clamped = max(0, min(100, blended))

        var liveFactors = [String]()
        liveFactors.append(String(format: "Live CPU: %.1f%%", process.cpuPercent))
        liveFactors.append(String(format: "Live RAM: %.0f MB", process.memoryMB))
        liveFactors.append("PID \(process.pid) · running as \(process.user)")

        return StartupScore(
            numeric:   clamped,
            level:     level(for: clamped),
            source:    .live,
            factors:   h.factors + liveFactors,
            liveCPU:   process.cpuPercent,
            liveMemMB: process.memoryMB,
            isRunning: true
        )
    }

    // MARK: — Process matching
    // Tries to match a LoginItem to a running process by:
    //   1. Last component of Program/ProgramArguments path
    //   2. Significant bundle ID segments
    //   3. Display name
    private func findProcess(for item: LoginItem, in processes: [AppProcess]) -> AppProcess? {
        // Build candidate names from the identifier and plist
        var candidates = Set<String>()
        candidates.insert(item.identifier.lowercased())

        // Bundle ID segments (skip short/generic ones)
        let stopWords: Set<String> = ["com", "app", "org", "net", "io", "co", "the"]
        item.identifier.components(separatedBy: ".")
            .filter { $0.count > 3 && !stopWords.contains($0.lowercased()) }
            .forEach { candidates.insert($0.lowercased()) }

        candidates.insert(item.displayName.lowercased())

        // Also try the binary name from the plist
        if let plistURL = item.plistURL,
           let dict = NSDictionary(contentsOf: plistURL) {
            let prog = (dict["Program"] as? String) ??
                       (dict["ProgramArguments"] as? [String])?.first ?? ""
            if !prog.isEmpty {
                candidates.insert(URL(fileURLWithPath: prog).lastPathComponent.lowercased())
            }
        }

        return processes.first { process in
            let pname = process.name.lowercased()
            return candidates.contains(where: { pname.contains($0) || $0.contains(pname) })
        }
    }

    // MARK: — Heuristic scoring (plist key analysis, no process needed)
    func heuristicScore(_ item: LoginItem) -> StartupScore {
        var pts     = 0
        var factors = [String]()

        // Type base weight
        switch item.type {
        case .launchDaemon:
            pts += 35; factors.append("Runs at boot as root (+35)")
        case .launchAgent:
            pts += 20; factors.append("Runs at every login (+20)")
        case .loginItem, .backgroundItem:
            pts += 10; factors.append("Opens at login (+10)")
        default:
            pts += 5
        }

        guard let plistURL = item.plistURL,
              let dict     = NSDictionary(contentsOf: plistURL) else {
            let c = max(0, min(100, pts))
            return StartupScore(numeric: c, level: level(for: c), source: .heuristic,
                                factors: factors, liveCPU: nil, liveMemMB: nil, isRunning: false)
        }

        // KeepAlive — always-running is the single biggest impact factor
        if let ka = dict["KeepAlive"] as? Bool, ka {
            pts += 25; factors.append("Always running, auto-restarts (+25)")
        } else if dict["KeepAlive"] is NSDictionary {
            pts += 12; factors.append("Conditionally keeps running (+12)")
        }

        // RunAtLoad — starts immediately, no trigger required
        if let ral = dict["RunAtLoad"] as? Bool, ral {
            pts += 10; factors.append("Starts immediately at login (+10)")
        }

        // StartInterval — frequent wakeups = steady CPU overhead
        if let interval = dict["StartInterval"] as? Int {
            if interval < 60 {
                pts += 15; factors.append("Wakes every \(interval)s — high overhead (+15)")
            } else if interval < 300 {
                pts += 8;  factors.append("Wakes every \(interval / 60)min (+8)")
            } else {
                pts += 3;  factors.append("Periodic wakeup (+3)")
            }
        }

        // Sockets — network listener must stay resident
        if dict["Sockets"] != nil {
            pts += 12; factors.append("Listens on a network socket (+12)")
        }

        // MachServices — IPC endpoint, always loaded in launchd
        if dict["MachServices"] != nil {
            pts += 8; factors.append("Registers a Mach IPC service (+8)")
        }

        // ProcessType
        if let procType = dict["ProcessType"] as? String {
            switch procType.lowercased() {
            case "interactive":
                pts += 5; factors.append("Interactive process priority (+5)")
            case "background", "adaptive":
                pts -= 5; factors.append("Background process priority (−5)")
            default: break
            }
        }

        // Binary size — larger executable = more I/O at launch
        let programPath = (dict["Program"] as? String) ??
                          (dict["ProgramArguments"] as? [String])?.first ?? ""
        if !programPath.isEmpty {
            let size = (try? FileManager.default.attributesOfItem(atPath: programPath))?[.size]
                as? Int64 ?? 0
            if size > 100_000_000 {
                pts += 12; factors.append("Very large binary >100 MB (+12)")
            } else if size > 50_000_000 {
                pts += 8;  factors.append("Large binary >50 MB (+8)")
            } else if size > 10_000_000 {
                pts += 4;  factors.append("Medium binary >10 MB (+4)")
            }
        }

        let clamped = max(0, min(100, pts))
        return StartupScore(
            numeric:   clamped,
            level:     level(for: clamped),
            source:    .heuristic,
            factors:   factors,
            liveCPU:   nil,
            liveMemMB: nil,
            isRunning: false
        )
    }

    // MARK: — Level thresholds
    func level(for score: Int) -> StartupScore.Level {
        switch score {
        case 0...25:  return .low
        case 26...50: return .medium
        case 51...74: return .high
        default:      return .critical
        }
    }

    // MARK: — Summary helpers
    var estimatedLoginDelay: String {
        let crit = Double(scoredItems.filter { $0.score.level == .critical }.count)
        let high = Double(scoredItems.filter { $0.score.level == .high    }.count)
        let est  = crit * 1.5 + high * 0.7
        if est < 0.5 { return "< 1s" }
        return String(format: "~%.0fs", est)
    }

    var impactDistribution: [StartupScore.Level: Int] {
        Dictionary(grouping: scoredItems) { $0.score.level }.mapValues { $0.count }
    }

    var liveCount: Int {
        scoredItems.filter { $0.score.source == .live }.count
    }
}
