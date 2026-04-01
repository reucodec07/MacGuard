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
    @State private var searchText = ""
    @StateObject private var scorer = StartupScorer()
    @StateObject private var manager = LoginItemsManager()
    @StateObject private var monitor = ProcessMonitor()

    @State private var filter: ScoreFilter = .all
    @State private var selectedItem: ScoredLoginItem?
    @State private var showInspector = false
    @State private var toast: Toast?
    @State private var cancellables = Set<AnyCancellable>()

    var filtered: [ScoredLoginItem] {
        let base: [ScoredLoginItem]
        switch filter {
        case .all:       base = scorer.scoredItems
        case .attention: base = scorer.scoredItems.filter { $0.score.level >= .high }
        case .live:      base = scorer.scoredItems.filter { $0.score.isRunning }
        }
        
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.item.displayName.lowercased().contains(q) ||
            $0.item.identifier.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                
                ScrollView {
                    VStack(spacing: 24) {
                        impactSummaryHero
                        
                        filterBar
                        
                        if manager.needsFDA {
                            BannerView(
                                title: "Full Disk Access Required",
                                subtitle: "Grant access in System Settings to see all startup items.",
                                style: .warning,
                                actionLabel: "Grant Access",
                                action: {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                                }
                            )
                        }
                        
                        if manager.isLoading && scorer.scoredItems.isEmpty {
                            loadingState
                        } else if filtered.isEmpty {
                            emptyState
                        } else {
                            itemsList
                        }
                    }
                    .padding(24)
                }
            }
            .blur(radius: showInspector ? 2 : 0)
            
            InspectorPane(title: "Impact Analysis", isPresented: $showInspector) {
                Group {
                    if let scored = selectedItem {
                        StartupImpactInspector(scored: scored) {
                            manager.toggle(scored.item) { ok, msg in
                                toast = ok ? .success("Updated startup status") : .error(msg)
                                manager.refresh()
                                showInspector = false
                            }
                        }
                    } else {
                        Color.clear
                    }
                }
            }
            
            if let t = toast {
                ToastView(toast: t) { toast = nil }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
    }

    // MARK: - Components

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Startup Impact")
                .font(.system(size: 20, weight: .bold))
            
            Spacer()
            
            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(manager.isLoading)
            
            TextField("Search Startup Items...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var impactSummaryHero: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Estimated Login Delay")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text(scorer.estimatedLoginDelay)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("Calculated from active startup items")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(StartupScore.Level.allCases.reversed(), id: \.self) { lvl in
                    let count = scorer.impactDistribution[lvl] ?? 0
                    if count > 0 {
                        HStack(spacing: 8) {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6)
                                .background(lvl.color.opacity(0.2))
                                .cornerRadius(6)
                            Text(lvl.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(lvl.color)
                    }
                }
            }
        }
        .padding(24)
        .background(.regularMaterial)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(ScoreFilter.allCases, id: \.self) { f in
                    Label(f.rawValue, systemImage: f.icon).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            
            Spacer()
            
            if scorer.liveCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: .green.opacity(0.5), radius: 3)
                    Text("\(scorer.liveCount) Running")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(20)
            }
        }
    }

    private var itemsList: some View {
        VStack(spacing: 0) {
            ForEach(filtered) { scored in
                Button(action: {
                    selectedItem = scored
                    showInspector = true
                }) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(scored.score.level.color.opacity(0.1))
                                .frame(width: 44, height: 44)
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
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scored.item.displayName)
                                .font(.system(size: 14, weight: .bold))
                            Text(scored.item.identifier)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        if scored.score.isRunning {
                           Circle().fill(Color.green).frame(width: 6, height: 6)
                        }
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(scored.score.numeric)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(scored.score.level.color)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(scored.score.level.color.opacity(0.2))
                                .frame(width: 40, height: 4)
                                .overlay(
                                    GeometryReader { g in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(scored.score.level.color)
                                            .frame(width: g.size.width * CGFloat(scored.score.numeric) / 100)
                                    }
                                )
                        }
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(Color.clear)
                }
                .buttonStyle(.plain)
                
                if scored.id != filtered.last?.id {
                    Divider().padding(.leading, 76)
                }
            }
        }
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Analyzing startup impact...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary.opacity(0.2))
            Text("No heavy startup items found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Logic

    private func startMonitoring() {
        monitor.setForeground()
        monitor.start()
        manager.refresh()

        manager.$isLoading
            .filter { !$0 }
            .combineLatest(monitor.$allProcesses)
            .receive(on: DispatchQueue.main)
            .sink { [weak scorer, weak manager] _, processes in
                guard let s = scorer, let m = manager, !m.isLoading else { return }
                s.scoreAll(m.items, liveProcesses: processes)
            }
            .store(in: &cancellables)
    }

    private func stopMonitoring() {
        monitor.stop()
        cancellables.removeAll()
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
