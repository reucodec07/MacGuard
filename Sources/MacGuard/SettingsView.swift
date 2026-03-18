import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold))

                notificationsSection
                Divider()
                autoKillSection
                launchAtLoginSection
            }
            .padding(20)
        }
        .frame(width: 450, height: 420)
    }

    private var autoKillSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-Kill")
                .font(.headline)

            HStack(alignment: .top) {
                Toggle("", isOn: $settings.autoKillEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatically kill processes exceeding CPU threshold")
                    Text("MacGuard will send SIGTERM to any process that exceeds the threshold below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.autoKillEnabled {
                HStack {
                    Text("CPU threshold:")
                        .frame(width: 120, alignment: .leading)
                    Slider(value: $settings.autoKillThreshold, in: 10...100, step: 5)
                        .tint(.red)
                    Text("\(Int(settings.autoKillThreshold))%")
                        .frame(width: 45, alignment: .trailing)
                        .monospacedDigit()
                        .foregroundColor(.red)
                }

                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("This forcibly terminates processes without saving their state. Use with caution.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alerts")
                .font(.headline)

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

            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: 10) {
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
                .transition(.opacity)
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startup")
                .font(.headline)

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { _ in loginItem.toggle() }
            ))

            Text(loginItem.statusLabel)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func sliderRow<Content: View>(
        title: String,
        valueText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            content()
        }
    }
}
