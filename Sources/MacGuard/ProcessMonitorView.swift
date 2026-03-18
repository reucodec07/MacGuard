import SwiftUI

// Column widths — all explicit, nothing uses minWidth/maxWidth near Dividers
private enum Col {
    static let pid:     CGFloat = 52
    static let name:    CGFloat = 210
    static let spark:   CGFloat = 90
    static let cpu:     CGFloat = 68
    static let ram:     CGFloat = 88
    static let threads: CGFloat = 68
    static let user:    CGFloat = 90
    static let actions: CGFloat = 130
    static let padH:    CGFloat = 16
}

struct ProcessMonitorView: View {
    @ObservedObject private var monitor  = ProcessMonitor.shared
    @ObservedObject private var s        = SettingsManager.shared
    @State private var search           = ""
    @State private var hoveredPID:      Int32?
    @State private var tickAngle:       Double = 0

    var displayed: [AppProcess] {
        guard !search.isEmpty else { return monitor.processes }
        let q = search.lowercased()
        return monitor.processes.filter {
            $0.name.lowercased().contains(q) ||
            "\($0.pid)".contains(q) ||
            $0.user.lowercased().contains(q)
        }
    }

    // System totals
    var totalCPU:  Double { monitor.processes.reduce(0) { $0 + $1.cpuPercent } }
    var totalRAM:  Double { monitor.processes.reduce(0) { $0 + $1.memoryMB   } }
    var procCount: Int    { monitor.allProcesses.count }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            statsStrip
            Divider()
            colHeaders
            Divider()
            list
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            monitor.setForeground()
            if !monitor.isRunning { monitor.start() }
        }
        .onDisappear {
            monitor.setBackground()
        }
    }

    // ── Top bar ──────────────────────────────────────────────

    var topBar: some View {
        HStack(spacing: 10) {
            // Title + live indicator
            HStack(spacing: 8) {
                Text("Activity Monitor")
                    .font(.system(size: 17, weight: .bold))

                // Animated pulse dot when running
                if monitor.isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: .green.opacity(0.6), radius: 3)
                }
            }

            Spacer()

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Search name, PID, user…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 190)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Sort picker
            Picker("", selection: $s.sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            .onChange(of: s.sortMode) { _ in monitor.refresh() }

            // Pause/resume
            Button {
                monitor.isRunning ? monitor.stop() : monitor.start()
            } label: {
                Image(systemName: monitor.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help(monitor.isRunning ? "Pause" : "Resume")

            // Manual refresh
            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Refresh now")
        }
        .padding(.horizontal, Col.padH)
        .padding(.vertical, 10)
    }

    // ── Stats strip ──────────────────────────────────────────

    var statsStrip: some View {
        HStack(spacing: 0) {
            // CPU
            SStatCell(
                icon: "cpu", label: "CPU Usage",
                value: String(format: "%.1f%%", totalCPU),
                color: totalCPU > 80 ? .red : totalCPU > 40 ? .orange : .blue
            )

            Divider()

            // RAM
            SStatCell(
                icon: "memorychip", label: "RAM Used",
                value: totalRAM >= 1024
                    ? String(format: "%.2f GB", totalRAM / 1024)
                    : String(format: "%.0f MB", totalRAM),
                color: totalRAM > 8000 ? .red : totalRAM > 4000 ? .orange : .purple
            )

            Divider()

            // Processes
            SStatCell(
                icon: "square.stack.3d.up", label: "Processes",
                value: "\(procCount)",
                color: .teal
            )

            Divider()

            // Threads (sum)
            SStatCell(
                icon: "arrow.triangle.branch", label: "Threads",
                value: "\(monitor.allProcesses.reduce(0) { $0 + $1.threads })",
                color: .indigo
            )
        }
        .frame(height: 46)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }

    // ── Column headers ───────────────────────────────────────

    var colHeaders: some View {
        HStack(spacing: 0) {
            Text("PID")
                .frame(width: Col.pid, alignment: .leading)
            Text("Process Name")
                .frame(width: Col.name, alignment: .leading)
            Text("CPU Trend")
                .frame(width: Col.spark, alignment: .center)
            Text("CPU %")
                .frame(width: Col.cpu, alignment: .trailing)
            Text("Memory")
                .frame(width: Col.ram, alignment: .trailing)
            Text("Threads")
                .frame(width: Col.threads, alignment: .trailing)
            Text("User")
                .frame(width: Col.user, alignment: .leading)
                .padding(.leading, 12)
            Spacer()
            Text("Actions")
                .frame(width: Col.actions, alignment: .center)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.horizontal, Col.padH)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    // ── Process list ─────────────────────────────────────────

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayed) { p in
                    AMProcessRow(
                        process:     p,
                        cpuHistory:  monitor.cpuTrend(for: p),
                        isHovered:   hoveredPID == p.pid,
                        threshold:   s.autoKillThreshold,
                        onQuit:      { monitor.quitProcess(p) },
                        onForceKill: { monitor.forceKillProcess(p) }
                    )
                    .onHover { hoveredPID = $0 ? p.pid : nil }

                    if p.id != displayed.last?.id {
                        Rectangle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 1)
                            .padding(.leading, Col.padH + 32)
                    }
                }
            }
        }
    }
}

// ── Stat cell ────────────────────────────────────────────────

struct SStatCell: View {
    let icon:  String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 110)
    }
}

// ── Process row ──────────────────────────────────────────────

struct AMProcessRow: View {
    let process:     AppProcess
    let cpuHistory:  [Double]
    let isHovered:   Bool
    let threshold:   Double
    let onQuit:      () -> Void
    let onForceKill: () -> Void
    @State private var appIcon: NSImage?

    var cpuColor: Color {
        process.cpuPercent > threshold ? .red :
        process.cpuPercent > 30        ? .orange : .blue
    }
    var ramColor: Color {
        process.memoryMB > 2000 ? .red :
        process.memoryMB > 800  ? .orange : .purple
    }

    var memLabel: String {
        process.memoryMB >= 1024
            ? String(format: "%.2f GB", process.memoryMB / 1024)
            : String(format: "%.0f MB", process.memoryMB)
    }

    var body: some View {
        HStack(spacing: 0) {
            // PID
            Text("\(process.pid)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: Col.pid, alignment: .leading)

            // Avatar + name
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(cpuColor.opacity(0.1))
                        .frame(width: 22, height: 22)
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                    } else {
                        Text(String(process.name.prefix(1)).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(cpuColor)
                    }
                }
                .onAppear {
                    guard appIcon == nil else { return }
                    if let app = NSRunningApplication(processIdentifier: process.pid),
                       let icon = app.icon {
                        appIcon = icon
                        return
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let home = NSHomeDirectory()
                        let candidates = [
                            "/Applications/\(process.name).app",
                            "\(home)/Applications/\(process.name).app"
                        ]
                        if let path = candidates.first(where: {
                            FileManager.default.fileExists(atPath: $0)
                        }) {
                            let icon = NSWorkspace.shared.icon(forFile: path)
                            DispatchQueue.main.async { appIcon = icon }
                        }
                    }
                }
                Text(process.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Col.name, alignment: .leading)

            // Sparkline
            SparklineView(
                data: cpuHistory, color: cpuColor,
                lineWidth: 1.5, showFill: true
            )
            .frame(width: Col.spark - 10, height: 22)
            .padding(.horizontal, 5)

            // CPU %
            Text(String(format: "%.1f%%", process.cpuPercent))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(cpuColor)
                .frame(width: Col.cpu, alignment: .trailing)

            // RAM
            Text(memLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(ramColor)
                .frame(width: Col.ram, alignment: .trailing)

            // Threads
            Text("\(process.threads)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: Col.threads, alignment: .trailing)

            // User
            Text(process.user)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: Col.user, alignment: .leading)
                .padding(.leading, 12)

            Spacer(minLength: 0)

            // Actions — always allocate the space, only show on hover
            // This prevents the row width from changing on hover
            HStack(spacing: 6) {
                if isHovered {
                    Button("Quit") { onQuit() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)

                    Button("Force Kill") { onForceKill() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
            .frame(width: Col.actions)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(.horizontal, Col.padH)
        .padding(.vertical, 6)
        .background(
            isHovered
                ? (process.cpuPercent > threshold
                   ? Color.red.opacity(0.04)
                   : Color.primary.opacity(0.03))
                : Color.clear
        )
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}
