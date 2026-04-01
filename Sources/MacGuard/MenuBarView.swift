import SwiftUI
import Foundation

struct MenuBarView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var hoveredProcess: AppProcess?
    
    init(monitor: ProcessMonitor) {
        self.monitor = monitor
    }
    
    var totalCPU: Double { monitor.allProcesses.reduce(0) { $0 + $1.cpuPercent } }
    var totalRAM: Double { monitor.allProcesses.reduce(0) { $0 + $1.memoryMB } }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView {
                VStack(spacing: 16) {
                    statsGrid
                    
                    processSection
                }
                .padding(16)
            }
            
            footer
        }
        .frame(width: 320, height: 480)
        .background(.ultraThinMaterial)
        .onAppear {
            monitor.setForeground()
            monitor.refresh()
        }
        .onDisappear {
            monitor.setBackground()
        }
    }

    // MARK: - Components

    private var header: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.accentColor)
            
            Text("MacGuard")
                .font(.system(size: 14, weight: .bold))
            
            Spacer()
            
            Button {
                NotificationCenter.default.post(name: .openMacGuardWindow, object: nil, userInfo: nil)
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Open Main Window")
            
            Button {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var statsGrid: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "CPU",
                value: String(format: "%.1f%%", totalCPU),
                icon: "cpu",
                color: .blue,
                history: monitor.allProcesses.prefix(1).first.map { monitor.cpuTrend(for: $0) } ?? []
            )
            
            StatCard(
                title: "RAM",
                value: totalRAM >= 1024 ? String(format: "%.1f GB", totalRAM/1024) : String(format: "%.0f MB", totalRAM),
                icon: "memorychip",
                color: .purple,
                history: monitor.allProcesses.prefix(1).first.map { monitor.ramTrend(for: $0) } ?? []
            )
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TOP PROCESSES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("Sort by CPU") { monitor.sortMode = .cpu }
                    Button("Sort by RAM") { monitor.sortMode = .memory }
                    Button("Sort by Threads") { monitor.sortMode = .threads }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            VStack(spacing: 8) {
                ForEach(monitor.processes.prefix(5)) { proc in
                    ProcessRow(proc: proc, isHovered: hoveredProcess == proc)
                        .onHover { hoveredProcess = $0 ? proc : nil }
                }
            }
            .animation(.spring(), value: monitor.processes)
        }
    }

    private var footer: some View {
        HStack {
            if !monitor.isRunning {
                Label("Paused", systemImage: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                StatusDot()
                Text("Live Monitoring")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1), alignment: .top)
    }
}

// MARK: - Subviews

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let history: [Double]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
        }
        .padding(12)
        .background(.regularMaterial)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct ProcessRow: View {
    let proc: AppProcess
    let isHovered: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 28, height: 28)
                Text(String(proc.name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(String(format: "PID: %d", proc.pid))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isHovered {
                Button {
                    ProcessMonitor.shared.forceKillProcess(proc)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", proc.cpuPercent))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(proc.memoryMB >= 1024 ? String(format: "%.1fG", proc.memoryMB/1024) : String(format: "%.0fM", proc.memoryMB))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(8)
    }
}

struct StatusDot: View {
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.3))
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 1.4 : 1.0)
                .opacity(isPulsing ? 0 : 1)
            
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}
