import SwiftUI

struct StartupImpactInspector: View {
    let scored: ScoredLoginItem
    let onDisable: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scored.score.level.color.opacity(0.1))
                            .frame(width: 56, height: 56)
                        if let appURL = scored.item.associatedApp {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                                .resizable().scaledToFit()
                                .frame(width: 40, height: 40).cornerRadius(8)
                        } else {
                            Image(systemName: scored.item.type.icon)
                                .font(.system(size: 24))
                                .foregroundColor(scored.item.type.color)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scored.item.displayName)
                            .font(.system(size: 18, weight: .bold))
                        Text(scored.item.identifier)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Divider()
                
                // Score Hero
                VStack(spacing: 8) {
                    Text("Impact Score")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .kerning(1)
                    
                    Text("\(scored.score.numeric)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(scored.score.level.color)
                    
                    HStack(spacing: 4) {
                        Image(systemName: scored.score.level.icon)
                        Text(scored.score.level.rawValue)
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(scored.score.level.color)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(scored.score.level.color.opacity(0.1))
                    .cornerRadius(20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.regularMaterial)
                .cornerRadius(16)
                
                // Live Metrics (if applicable)
                if scored.score.isRunning,
                   let cpu = scored.score.liveCPU,
                   let mem = scored.score.liveMemMB {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LIVE ACTIVITY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 16) {
                            LiveMetricCard(label: "CPU", value: String(format: "%.1f%%", cpu), color: .blue)
                            LiveMetricCard(label: "Memory", value: mem >= 1024 ? String(format: "%.1fG", mem/1024) : String(format: "%.0fM", mem), color: .purple)
                        }
                    }
                }
                
                // Breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text("SCORE BREAKDOWN")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(scored.score.factors, id: \.self) { factor in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(scored.score.level.color.opacity(0.6))
                                    .padding(.top, 2)
                                Text(factor)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(12)
                }
                
                Spacer(minLength: 40)
                
                // Actions
                if scored.item.isEnabled {
                    Button(action: onDisable) {
                        Label("Disable at Startup", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                } else {
                    HStack {
                        Spacer()
                        Label("Already disabled", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding(24)
        }
    }
}

private struct LiveMetricCard: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(10)
    }
}
