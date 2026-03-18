import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────
//  Design constants — every element sized from these, nothing
//  uses frame(maxWidth: .infinity) inside an HStack with Dividers
// ─────────────────────────────────────────────────────────────
private enum MB {
    static let width:     CGFloat = 320   // popover width (match contentSize in controller)
    static let padH:      CGFloat = 14    // horizontal padding for all rows
    static let rowH:      CGFloat = 40    // standard row height
    static let avatarW:   CGFloat = 28    // process avatar square
    static let nameW:     CGFloat = 118   // process name column
    static let sparkW:    CGFloat = 44    // sparkline width
    static let sparkH:    CGFloat = 14    // sparkline height
    static let metricW:   CGFloat = 36    // metric value (e.g. "14%")
    static let killW:     CGFloat = 20    // kill button slot
    // Stats row: three equal cells
    static let statW:     CGFloat = (width) / 3   // ≈ 106.67
}

struct MenuBarView: View {
    @ObservedObject var monitor:          ProcessMonitor
    @ObservedObject private var settings = SettingsManager.shared

    var top5: [AppProcess] { Array(monitor.processes.prefix(5)) }

    var totalCPU: Double { monitor.processes.reduce(0) { $0 + $1.cpuPercent } }
    var totalRAM: Double { monitor.processes.reduce(0) { $0 + $1.memoryMB  } }
    var cpuColor: Color  { totalCPU > 80 ? .red : totalCPU > 40 ? .orange : .blue }
    var ramColor: Color  { totalRAM > 8000 ? .red : totalRAM > 4000 ? .orange : .purple }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            sortRow
            Divider()
            statsRow
            Divider()
            processesSection
            Divider()
            footerRow
        }
        .frame(width: MB.width)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Nothing needed here now
        }
    }

    // ── 1. Header — 42pt ─────────────────────────────────────
    // Logo · Title · [refresh] · [⊡ open]
    // Sort picker is NOT here — it caused title wrapping at 320px

    var headerRow: some View {
        HStack(spacing: 0) {
            // Logo
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(
                        colors: [Color(hex: "3B82F6"), Color(hex: "6366F1")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.leading, MB.padH)

            Text("MacGuard")
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 8)

            Spacer()

            // Refresh
            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("Refresh")
                    // Settings
                    Button {
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("Settings")

            // Open main window
            Button {
                NotificationCenter.default.post(name: .openMacGuardWindow, object: nil)
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.trailing, MB.padH)
            .help("Open MacGuard")
        }
        .frame(height: 42)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // ── 2. Sort row — 34pt ───────────────────────────────────
    // Compact segmented picker on its own row

    var sortRow: some View {
        HStack(spacing: 8) {
            Text("Sort")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Picker("", selection: $settings.sortMode) {
                ForEach(SortMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: settings.sortMode) { _ in monitor.refresh() }
        }
        .padding(.horizontal, MB.padH)
        .frame(height: 34)
    }

    // ── 3. Stats row — 52pt ──────────────────────────────────
    // Three equal fixed-width cells separated by Dividers
    // Each cell: 320/3 ≈ 106pt — enough for icon + value + label

    var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                icon: "cpu", color: cpuColor,
                value: String(format: "%.0f%%", totalCPU),
                label: "Total CPU"
            )
            .frame(width: MB.statW)

            Divider()

            statCell(
                icon: "memorychip", color: ramColor,
                value: totalRAM >= 1024
                    ? String(format: "%.1f GB", totalRAM/1024)
                    : String(format: "%.0f MB", totalRAM),
                label: "Total RAM"
            )
            .frame(width: MB.statW)

            Divider()

            statCell(
                icon: "square.stack.3d.up", color: .teal,
                value: "\(monitor.allProcesses.count)",
                label: "Processes"
            )
            .frame(width: MB.statW)
        }
        .frame(height: 52)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    func statCell(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    // ── 4. Processes section ─────────────────────────────────

    var processesSection: some View {
        VStack(spacing: 0) {
            // Section header — 28pt
            HStack {
                Text("TOP PROCESSES")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundColor(.secondary)
                    .kerning(0.5)
                Spacer()
                if monitor.isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, MB.padH)
            .frame(height: 28)

            if monitor.processes.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75)
                        Text("Loading…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(top5) { p in
                        MBProcessRow(
                            process:    p,
                            cpuHistory: monitor.cpuTrend(for: p),
                            sortMode:   settings.sortMode,
                            onKill:     { monitor.forceKillProcess(p) }
                        )
                        if p.id != top5.last?.id {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, MB.padH + MB.avatarW + 8)
                        }
                    }
                }
            }
        }
    }

    // ── 6. Footer — 40pt ─────────────────────────────────────

    var footerRow: some View {
        HStack {
            Text("MacGuard 1.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openMacGuardWindow, object: nil)
            } label: {
                Text("Open App")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, MB.padH)
        .frame(height: 36)
    }
}

// ── Process Row ───────────────────────────────────────────────
// Fixed widths for every column — nothing flexible inside this HStack

struct MBProcessRow: View {
    let process:    AppProcess
    let cpuHistory: [Double]
    let sortMode:   SortMode
    let onKill:     () -> Void
    @State private var hovered = false

    var cpuColor: Color { process.cpuPercent > 60 ? .red : process.cpuPercent > 25 ? .orange : .blue }
    var ramColor: Color { process.memoryMB > 800  ? .red : process.memoryMB > 400  ? .orange : .purple }
    var accent:   Color { sortMode == .memory ? ramColor : cpuColor }

    var metric: String {
        switch sortMode {
        case .cpu:            return String(format: "%.0f%%", process.cpuPercent)
        case .memory,.threads:
            return process.memoryMB >= 1024
                ? String(format: "%.1fG", process.memoryMB/1024)
                : String(format: "%.0fM", process.memoryMB)
        }
    }

    var subtitle: String {
        let cpu = String(format: "%.0f%%", process.cpuPercent)
        let ram = process.memoryMB >= 1024
            ? String(format: "%.1fGB", process.memoryMB/1024)
            : String(format: "%.0fMB", process.memoryMB)
        return "\(cpu) CPU · \(ram) RAM"
    }

    private var resolvedIcon: NSImage? {
        // Prefer exact app bundle under /Applications for app-like process names.
        let appPath = "/Applications/\(process.name).app"
        if FileManager.default.fileExists(atPath: appPath) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // Avatar — 28x28, fixed
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: MB.avatarW, height: MB.avatarW)

                if let icon = resolvedIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: MB.avatarW - 6, height: MB.avatarW - 6)
                        .cornerRadius(5)
                } else {
                    Text(String(process.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            // Name + sublabel — fixed 118pt
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: MB.nameW, alignment: .leading)

            // Sparkline — fixed 44×14
            SparklineView(data: cpuHistory, color: cpuColor, lineWidth: 1.0, showFill: false)
                .frame(width: MB.sparkW, height: MB.sparkH)

            // Metric — fixed 36pt, right-aligned
            Text(metric)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(accent)
                .lineLimit(1)
                .frame(width: MB.metricW, alignment: .trailing)

            // Kill slot — always 20pt wide, button appears on hover only
            // Fixed width prevents layout shift when button appears/disappears
            ZStack {
                Color.clear.frame(width: MB.killW, height: MB.killW)
                if hovered {
                    Button(action: onKill) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
        }
        .padding(.leading, MB.padH)
        .padding(.trailing, MB.padH - 2)
        .frame(height: MB.rowH)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovered)
    }
}

// ── Slider Row ────────────────────────────────────────────────

struct MBSlider: View {
    let icon:  String
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step:  Double
    let unit:  String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10)).foregroundColor(color).frame(width: 14)
            Text(label)
                .font(.system(size: 11)).frame(width: 28, alignment: .leading)
            Slider(value: $value, in: range, step: step).tint(color)
            Text("\(Int(value))\(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color).frame(width: 46, alignment: .trailing)
        }
    }
}

// ── Hex color helper ──────────────────────────────────────────

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
