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
    @State private var searchText = ""
    @ObservedObject private var monitor = ProcessMonitor.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var hoveredPID: Int32?
    @State private var selectedProcess: AppProcess?
    @State private var showInspector = false

    var displayed: [AppProcess] {
        let list = monitor.processes
        guard !searchText.isEmpty else { return list }
        let q = searchText.lowercased()
        return list.filter {
            $0.name.lowercased().contains(q) ||
            "\($0.pid)".contains(q) ||
            $0.user.lowercased().contains(q)
        }
    }

    var totalCPU: Double { monitor.allProcesses.reduce(0) { $0 + $1.cpuPercent } }
    var totalRAM: Double { monitor.allProcesses.reduce(0) { $0 + $1.memoryMB } }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                
                ScrollView {
                    VStack(spacing: 24) {
                        systemHealthGauges
                        
                        processListSection
                    }
                    .padding(24)
                }
            }
            .blur(radius: showInspector ? 2 : 0)
            
            InspectorPane(title: "Process Details", isPresented: $showInspector) {
                Group {
                    if let process = selectedProcess {
                        ProcessInspector(
                            process: process,
                            cpuHistory: monitor.cpuTrend(for: process),
                            ramHistory: monitor.ramTrend(for: process)
                        )
                    } else {
                        Color.clear
                    }
                }
            }
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

    // MARK: - Components

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Activity Monitor")
                .font(.system(size: 20, weight: .bold))
            
            if monitor.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.5), radius: 3)
            }
            
            Spacer()
            
            Picker("Sort", selection: $settings.sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            
            TextField("Search Processes...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            
            HStack(spacing: 8) {
                Button {
                    monitor.isRunning ? monitor.stop() : monitor.start()
                } label: {
                    Image(systemName: monitor.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var systemHealthGauges: some View {
        HStack(spacing: 20) {
            GaugeCard(
                title: "System CPU",
                value: totalCPU,
                maxValue: 800, // 8 cores
                unit: "%",
                color: .blue,
                history: monitor.allProcesses.prefix(1).first.map { monitor.cpuTrend(for: $0) } ?? []
            )
            
            GaugeCard(
                title: "Memory Pressure",
                value: totalRAM / 1024,
                maxValue: 16, // Assume 16GB
                unit: "GB",
                color: .purple,
                history: monitor.allProcesses.prefix(1).first.map { monitor.ramTrend(for: $0) } ?? []
            )
            
            GaugeCard(
                title: "Processes",
                value: Double(monitor.allProcesses.count),
                maxValue: 500,
                unit: "",
                color: .teal,
                history: []
            )
        }
    }

    private var processListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Top Processes")
                .font(.headline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 0) {
                ForEach(displayed.prefix(20)) { process in
                    ProcessMonitorRow(
                        process: process,
                        cpuHistory: monitor.cpuTrend(for: process),
                        ramHistory: monitor.ramTrend(for: process),
                        isHovered: hoveredPID == process.pid,
                        onSelect: {
                            selectedProcess = process
                            showInspector = true
                        }
                    )
                    .onHover { hovered in
                        hoveredPID = hovered ? process.pid : nil
                    }
                    
                    if process.id != displayed.prefix(20).last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .animation(.default, value: monitor.processes)
            .background(.regularMaterial)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
}

private struct GaugeCard: View {
    let title: String
    let value: Double
    let maxValue: Double
    let unit: String
    let color: Color
    let history: [Double]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: min(value, maxValue), total: maxValue)
                .tint(color)
                .scaleEffect(x: 1, y: 0.5, anchor: .center)
            
            if !history.isEmpty {
                SparklineView(data: history, color: color, lineWidth: 1, showFill: false)
                    .frame(height: 20)
                    .opacity(0.4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ProcessMonitorRow: View {
    let process: AppProcess
    let cpuHistory: [Double]
    let ramHistory: [Double]
    let isHovered: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 32, height: 32)
                    Text(String(process.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("PID: \(process.pid)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Mini Sparks
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.blue)
                        SparklineView(data: cpuHistory, color: .blue, lineWidth: 1, showFill: false)
                            .frame(width: 40, height: 12)
                            .opacity(0.5)
                    }
                    .frame(width: 60)
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(process.memoryMB >= 1024 ? String(format: "%.1fG", process.memoryMB/1024) : String(format: "%.0fM", process.memoryMB))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.purple)
                        SparklineView(data: ramHistory, color: .purple, lineWidth: 1, showFill: false)
                            .frame(width: 40, height: 12)
                            .opacity(0.5)
                    }
                    .frame(width: 60)
                }
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
