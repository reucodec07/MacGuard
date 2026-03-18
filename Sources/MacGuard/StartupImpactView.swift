import SwiftUI
import Combine

// MARK: — Filter

enum ScoreFilter: String, CaseIterable {
    case all       = "All"
    case attention = "Needs Attention"
    case live      = "Running Now"

    var icon: String {
        switch self {
        case .all:       return "list.bullet"
        case .attention: return "exclamationmark.triangle.fill"
        case .live:      return "waveform"
        }
    }
}

// MARK: — Main View

struct StartupImpactView: View {
    @StateObject private var scorer  = StartupScorer()
    @StateObject private var manager = LoginItemsManager()
    // Dedicated ProcessMonitor — runs at 3s foreground poll while this tab is visible
    @StateObject private var monitor = ProcessMonitor()

    @State private var filter:      ScoreFilter = .all
    @State private var expandedID:  UUID?
    @State private var resultMsg    = ""
    @State private var resultOK     = true
    @State private var showResult   = false

    // Combine: re-score whenever ProcessMonitor publishes a new process snapshot
    @State private var cancellables = Set<AnyCancellable>()

    var filtered: [ScoredLoginItem] {
        switch filter {
        case .all:       return scorer.scoredItems
        case .attention: return scorer.scoredItems.filter { $0.score.level >= .high }
        case .live:      return scorer.scoredItems.filter { $0.score.isRunning }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()
            filterBar
            Divider()
            listBody
        }
        .onAppear  { startMonitoring() }
        .onDisappear { stopMonitoring() }
        .alert(resultOK ? "Done" : "Error", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: { Text(resultMsg) }
    }

    // MARK: — Start / stop
    private func startMonitoring() {
        monitor.setForeground()
        monitor.start()

        // Load login items once, then re-score on every process poll
        manager.refresh()

        // Re-score whenever login items finish loading OR processes update
        manager.$isLoading
            .filter { !$0 }
            .combineLatest(monitor.$allProcesses)
            .receive(on: DispatchQueue.main)
            .sink { [weak scorer = scorer, weak manager = manager] _, processes in
                guard let s = scorer, let m = manager, !m.isLoading else { return }
                // Pass the FULL process list (not just top-N) — monitor.processes
                // is already the full unsorted list before prefix() in background mode
                s.scoreAll(m.items, liveProcesses: processes)
            }
            .store(in: &cancellables)
    }

    private func stopMonitoring() {
        monitor.stop()
        cancellables.removeAll()
    }

    // MARK: — Summary header
    var summaryHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Startup Impact")
                    .font(.title2).bold()
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Estimated login delay: \(scorer.estimatedLoginDelay)")
                        .font(.caption).foregroundColor(.secondary)
                    if scorer.liveCount > 0 {
                        Text("·").font(.caption).foregroundColor(.secondary)
                        Image(systemName: "waveform")
                            .font(.system(size: 10)).foregroundColor(.green)
                        Text("\(scorer.liveCount) running now")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Distribution badges
            HStack(spacing: 6) {
                ForEach(StartupScore.Level.allCases.reversed(), id: \.self) { lvl in
                    let count = scorer.impactDistribution[lvl] ?? 0
                    if count > 0 {
                        DistributionBadge(level: lvl, count: count)
                    }
                }
            }

            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(manager.isLoading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: — Filter bar
    var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(ScoreFilter.allCases, id: \.self) { f in
                let selected = filter == f
                Button { filter = f } label: {
                    HStack(spacing: 5) {
                        Image(systemName: f.icon).font(.system(size: 11))
                        Text(f.rawValue).font(.system(size: 12))
                        if f == .live && scorer.liveCount > 0 {
                            Text("\(scorer.liveCount)")
                                .font(.system(size: 10))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.green.opacity(selected ? 0.3 : 0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected ? Color.accentColor : Color.clear)
                    .foregroundColor(selected ? .white : .primary)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
            }
            Spacer()

            // Live indicator dot
            if scorer.liveCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Live · updates every 3s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: — List body
    @ViewBuilder
    var listBody: some View {
        if manager.needsFDA {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access required for complete results")
                        .font(.caption).fontWeight(.semibold)
                    Text("Grant access in System Settings → Privacy & Security → Full Disk Access")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Button("Grant Access") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }

        if manager.isLoading && scorer.scoredItems.isEmpty {
            Spacer()
            HStack { Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading startup items…").foregroundColor(.secondary)
                }
                Spacer()
            }
            Spacer()

        } else if filtered.isEmpty {
            Spacer()
            HStack { Spacer()
                VStack(spacing: 10) {
                    Image(systemName: filter == .live ? "waveform" : "checkmark.seal")
                        .font(.system(size: 44)).foregroundColor(.secondary.opacity(0.3))
                    Text(filter == .live
                         ? "No startup items are running right now"
                         : "No items in this category")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                Spacer()
            }
            Spacer()

        } else {
            // All-heuristic disclaimer (disappears as processes are matched)
            if scorer.liveCount == 0 && !scorer.scoredItems.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue).font(.system(size: 11))
                    Text("Scores are estimated from plist analysis. Items currently running will show live CPU and RAM automatically.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.blue.opacity(0.05))
                .padding(.horizontal, 8).padding(.top, 6)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { scored in
                        ScoreRow(
                            scored:     scored,
                            isExpanded: expandedID == scored.id,
                            onExpand: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedID = expandedID == scored.id ? nil : scored.id
                                }
                            },
                            onDisable: {
                                manager.toggle(scored.item) { ok, msg in
                                    resultOK = ok; resultMsg = msg; showResult = true
                                    manager.refresh()
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
            }
        }
    }
}

// MARK: — Score Row

struct ScoreRow: View {
    let scored:     ScoredLoginItem
    let isExpanded: Bool
    let onExpand:   () -> Void
    let onDisable:  () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // App icon or type icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(scored.score.level.color.opacity(0.08))
                        .frame(width: 42, height: 42)
                    if let appURL = scored.item.associatedApp {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable().scaledToFit()
                            .frame(width: 32, height: 32).cornerRadius(6)
                    } else {
                        Image(systemName: scored.item.type.icon)
                            .font(.system(size: 18))
                            .foregroundColor(scored.item.type.color)
                    }
                }

                // Name + badges
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(scored.item.displayName)
                            .fontWeight(.medium)
                            .foregroundColor(scored.item.isEnabled ? .primary : .secondary)
                        LevelBadge(level: scored.score.level)
                        SourceBadge(source: scored.score.source)
                    }
                    Text(scored.item.identifier)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Text(scored.item.startupScope)
                        .font(.caption2).foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                // Live CPU/RAM pills (visible only when process is running)
                if scored.score.isRunning,
                   let cpu = scored.score.liveCPU,
                   let mem = scored.score.liveMemMB {
                    HStack(spacing: 6) {
                        LivePill(label: String(format: "%.1f%%", cpu),
                                 icon: "cpu", color: cpu > 30 ? .orange : .blue)
                        LivePill(
                            label: mem >= 1024
                                ? String(format: "%.1fG", mem / 1024)
                                : String(format: "%.0fM", mem),
                            icon: "memorychip",
                            color: mem > 500 ? .orange : .purple)
                    }
                }

                // Numeric score + bar
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(scored.score.numeric)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(scored.score.level.color)
                    ScoreBar(value: scored.score.numeric, color: scored.score.level.color)
                        .frame(width: 72, height: 5)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .frame(width: 18)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onExpand() }
            .onHover { hovered = $0 }
            .background(hovered ? Color.primary.opacity(0.04) : Color.clear)

            // Expanded detail
            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.horizontal, 12)

            // Score factors
            if !scored.score.factors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Score breakdown")
                        .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    ForEach(scored.score.factors, id: \.self) { factor in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(scored.score.level.color)
                                .frame(width: 4, height: 4)
                            Text(factor).font(.caption).foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            // Action buttons
            HStack(spacing: 8) {
                if scored.item.isEnabled {
                    Button { onDisable() } label: {
                        Label("Disable at Startup", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                } else {
                    Label("Already disabled", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }
}

// MARK: — Supporting views

struct LivePill: View {
    let label: String
    let icon:  String
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(5)
    }
}

struct LevelBadge: View {
    let level: StartupScore.Level
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: level.icon).font(.system(size: 8))
            Text(level.rawValue).font(.system(size: 8, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(level.color)
        .cornerRadius(4)
    }
}

struct SourceBadge: View {
    let source: StartupScore.Source
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.icon).font(.system(size: 8))
            Text(source.label).font(.system(size: 8))
        }
        .foregroundColor(source == .live ? .green : .secondary)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(source == .live
                    ? Color.green.opacity(0.12)
                    : Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }
}

struct ScoreBar: View {
    let value: Int
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.2))
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, value))) / 100.0)
                    .animation(.easeInOut(duration: 0.3), value: value)
            }
        }
    }
}

struct DistributionBadge: View {
    let level: StartupScore.Level
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.icon)
                .font(.system(size: 10)).foregroundColor(level.color)
            Text("\(count) \(level.rawValue)")
                .font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(level.color.opacity(0.1))
        .cornerRadius(6)
    }
}
