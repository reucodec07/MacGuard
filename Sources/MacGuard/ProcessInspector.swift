import SwiftUI

struct ProcessInspector: View {
    let process: AppProcess
    let cpuHistory: [Double]
    let ramHistory: [Double]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 48, height: 48)
                        Text(String(process.name.prefix(1)).uppercased())
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.name)
                            .font(.system(size: 18, weight: .bold))
                        Text("PID: \(process.pid)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Metrics
                VStack(spacing: 16) {
                    MetricRow(
                        label: "CPU Usage",
                        value: String(format: "%.1f%%", process.cpuPercent),
                        color: .blue,
                        history: cpuHistory
                    )
                    
                    MetricRow(
                        label: "Memory",
                        value: process.memoryMB >= 1024 ? String(format: "%.2f GB", process.memoryMB / 1024) : String(format: "%.0f MB", process.memoryMB),
                        color: .purple,
                        history: ramHistory
                    )
                }
                
                Divider()
                
                // Details
                VStack(alignment: .leading, spacing: 12) {
                    DetailItem(label: "User", value: process.user)
                    DetailItem(label: "Threads", value: "\(process.threads)")
                    DetailItem(label: "Status", value: "Running")
                }
                
                Spacer(minLength: 40)
                
                // Actions
                VStack(spacing: 12) {
                    Button(action: {
                        ProcessMonitor.shared.quitProcess(process)
                    }) {
                        Label("Quit Process", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button(action: {
                        ProcessMonitor.shared.forceKillProcess(process)
                    }) {
                        Label("Force Kill", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                }
            }
            .padding(24)
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    let color: Color
    let history: [Double]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            
            SparklineView(data: history, color: color, lineWidth: 2, showFill: true)
                .frame(height: 60)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
        }
    }
}

private struct DetailItem: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 13))
    }
}
