import Foundation
import Darwin

struct AppProcess: Identifiable, Equatable {
    let pid: Int32
    var id: Int32 { pid }
    let name: String
    let cpuPercent: Double
    let memoryMB: Double
    let threads: Int
    let user: String
}

enum SortMode: String, CaseIterable {
    case cpu     = "CPU"
    case memory  = "RAM"
    case threads = "Threads"
}

class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published var processes:    [AppProcess]      = []
    @Published var allProcesses: [AppProcess]      = []
    @Published var cpuSnapshots: [Int32: [Double]] = [:]
    @Published var ramSnapshots: [Int32: [Double]] = [:]
    @Published var isRunning     = false
    @Published var isFetching    = false   // true only while a ps poll is in flight

    private let historyLength    = 20
    private var timer: Timer?
    private var isBackground     = true {
        didSet { guard oldValue != isBackground else { return }; restart() }
    }

    var sortMode: SortMode {
        get { SettingsManager.shared.sortMode }
        set { SettingsManager.shared.sortMode = newValue }
    }

    private var pollInterval: TimeInterval { isBackground ? 30.0 : 1.0 }
    private var processLimit:  Int         { isBackground ? 15   : 150  }

    func setForeground() { isBackground = false }
    func setBackground()  { isBackground = true  }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        // NOTE: intentionally do NOT clear `processes` — the last snapshot
        // stays visible so the list doesn't go blank when the user pauses.
    }

    private func restart() {
        timer?.invalidate(); timer = nil
        if isRunning { refresh(); scheduleTimer() }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !isFetching else { return }   // skip if a poll is already running

        DispatchQueue.main.async { self.isFetching = true }

        let currentSort = sortMode
        let limit       = processLimit
        let maxHistory  = historyLength

        // FIX: use correct QoS — .userInitiated for foreground (fast, responsive),
        //      .utility for background (low-energy, throttled).
        let qos: DispatchQoS.QoSClass = isBackground ? .utility : .userInitiated

        DispatchQueue.global(qos: qos).async { [weak self] in
            guard let self else { return }

            // ── ps call: pid, %cpu, rss (KB), wq (Mach thread count), user, comm ──
            // wq = number of Mach workqueue threads; best proxy for thread count
            // available from plain `ps` without elevated privileges.
            let task = Process()
            task.executableURL  = URL(fileURLWithPath: "/bin/ps")
            task.arguments      = ["-axo", "pid=,pcpu=,rss=,wq=,user=,comm="]
            let pipe            = Pipe()
            task.standardOutput = pipe
            task.standardError  = Pipe()

            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                guard let output = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async { self.isFetching = false }
                    return
                }

                var result: [AppProcess] = []
                for line in output.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { continue }
                    // fields: pid, pcpu, rss, wq, user, comm (comm may contain spaces)
                    let parts = t.split(separator: " ", maxSplits: 5,
                                        omittingEmptySubsequences: true)
                    guard parts.count >= 6,
                          let pid     = Int32(parts[0]),
                          let cpu     = Double(parts[1]),
                          let rss     = Double(parts[2]),
                          let threads = Int(parts[3]) else { continue }

                    result.append(AppProcess(
                        pid:        pid,
                        name:       URL(fileURLWithPath: String(parts[5])).lastPathComponent,
                        cpuPercent: cpu,
                        memoryMB:   rss / 1024.0,
                        threads:    threads,
                        user:       String(parts[4])
                    ))
                }

                // ── existing sort logic stays here ──
                var sorted: [AppProcess]
                switch currentSort {
                case .cpu:     sorted = result.sorted { $0.cpuPercent > $1.cpuPercent }
                case .memory:  sorted = result.sorted { $0.memoryMB   > $1.memoryMB   }
                case .threads: sorted = result.sorted { $0.threads    > $1.threads    }
                }
                let displayList = Array(sorted.prefix(limit))

                let activePIDs = Set(result.map { $0.pid })
                var cpuSnap = self.cpuSnapshots
                var ramSnap = self.ramSnapshots
                cpuSnap = cpuSnap.filter { activePIDs.contains($0.key) }
                ramSnap = ramSnap.filter { activePIDs.contains($0.key) }

                for p in result {
                    var c = cpuSnap[p.pid] ?? []
                    c.append(p.cpuPercent)
                    if c.count > maxHistory { c.removeFirst() }
                    cpuSnap[p.pid] = c

                    var r = ramSnap[p.pid] ?? []
                    r.append(p.memoryMB)
                    if r.count > maxHistory { r.removeFirst() }
                    ramSnap[p.pid] = r
                }

                DispatchQueue.main.async {
                    self.allProcesses  = sorted
                    self.processes     = displayList
                    self.cpuSnapshots  = cpuSnap
                    self.ramSnapshots  = ramSnap
                    self.isFetching    = false

                    let s = SettingsManager.shared
                    if s.notificationsEnabled {
                        for p in sorted.prefix(10) { NotificationManager.shared.checkProcess(p) }
                    }
                    if s.autoKillEnabled {
                        for p in sorted where p.cpuPercent > s.autoKillThreshold {
                            Darwin.kill(p.pid, SIGTERM)
                        }
                    }
                }
            } catch {
                print("ps error: \(error)")
                DispatchQueue.main.async { self.isFetching = false }
            }
        }
    }

    func cpuTrend(for process: AppProcess) -> [Double] { cpuSnapshots[process.pid] ?? [] }
    func ramTrend(for process: AppProcess) -> [Double] { ramSnapshots[process.pid] ?? [] }
    func history(for process: AppProcess)  -> [Double] { cpuTrend(for: process) }

    func quitProcess(_ p: AppProcess) {
        Darwin.kill(p.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    func forceKillProcess(_ p: AppProcess) {
        Darwin.kill(p.pid, SIGKILL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }
}
