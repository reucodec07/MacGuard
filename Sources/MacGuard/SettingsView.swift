import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 8)

                SectionCard(title: "Alerts", icon: "bell.badge.fill") {
                    notificationsSection
                }
                
                SectionCard(title: "Auto-Kill", icon: "bolt.fill") {
                    autoKillSection
                }
                
                SectionCard(title: "Startup", icon: "power") {
                    launchAtLoginSection
                }
                
                SectionCard(title: "AI Insights", icon: "sparkles") {
                    aiInsightsSection
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
    }

    private var autoKillSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Toggle("", isOn: $settings.autoKillEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatically kill processes exceeding CPU threshold")
                        .font(.system(size: 13, weight: .medium))
                    Text("MacGuard will send SIGTERM to any process that exceeds the threshold below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.autoKillEnabled {
                VStack(spacing: 12) {
                    HStack {
                        Text("CPU threshold")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(Int(settings.autoKillThreshold))%")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundColor(.red)
                    }
                    Slider(value: $settings.autoKillThreshold, in: 10...100, step: 5)
                        .tint(.red)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)

                BannerView(
                    title: "Force Termination",
                    subtitle: "This terminates processes without saving. Use with caution.",
                    style: .warning,
                    actionLabel: nil,
                    action: nil
                )
            }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable CPU and RAM alerts", isOn: Binding(
                get: { settings.notificationsEnabled },
                set: { enabled in
                    if enabled {
                        NotificationManager.shared.requestPermission()
                    } else {
                        settings.notificationsEnabled = false
                    }
                }
            ))
            .font(.system(size: 13, weight: .medium))

            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: 16) {
                    sliderRow(
                        title: "CPU Alert Threshold",
                        valueText: "\(Int(settings.cpuAlertThreshold))%"
                    ) {
                        Slider(value: $settings.cpuAlertThreshold, in: 10...100, step: 5)
                    }

                    sliderRow(
                        title: "RAM Alert Threshold",
                        valueText: "\(Int(settings.ramAlertThreshold)) MB"
                    ) {
                        Slider(value: $settings.ramAlertThreshold, in: 100...2000, step: 100)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if loginItem.status == .requiresApproval {
                BannerView(
                    title: "Action Required",
                    subtitle: "Allow MacGuard to run at login in System Settings.",
                    style: .critical,
                    actionLabel: "Open Settings",
                    action: {
                        Task { await loginItem.toggle() }
                    }
                )
                .padding(.bottom, 4)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch MacGuard at Login")
                        .font(.system(size: 13, weight: .medium))
                    Text(loginItem.statusLabel)
                        .font(.caption)
                        .foregroundColor(loginItem.statusColor)
                }
                
                Spacer()
                
                if loginItem.isBusy {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                }
                
                Button(action: {
                    Task { await loginItem.toggle() }
                }) {
                    Text(loginItem.actionLabel)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(loginItem.buttonTintColor)
                .disabled(!loginItem.canToggle)
            }
            
            if !loginItem.statusHelp.isEmpty {
                Text(loginItem.statusHelp)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Anthropic API Key")
                    .font(.system(size: 13, weight: .medium))
                
                SecureField("sk-ant-...", text: $settings.anthropicApiKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Your API key is stored locally in your keychain and is only used to communicate with Anthropic's Claude API for file analysis.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Link(destination: URL(string: "https://console.anthropic.com/")!) {
                Label("Get API Key", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .bold))
            }
        }
    }

    private func sliderRow<Content: View>(
        title: String,
        valueText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundColor(.accentColor)
            }
            content()
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }
            
            content()
        }
        .padding(20)
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
