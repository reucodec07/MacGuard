import SwiftUI

// MARK: — Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case activity  = "Activity"
    case uninstall = "Uninstaller"
    case loginItems = "Login Items"
    case startup   = "Startup"
    case disk      = "Disk"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .activity:   return "cpu"
        case .uninstall:  return "trash"
        case .loginItems: return "person.badge.clock"
        case .startup:    return "bolt"
        case .disk:       return "internaldrive"
        }
    }

    var accentColor: Color {
        switch self {
        case .activity:   return .blue
        case .uninstall:  return .red
        case .loginItems: return .indigo
        case .startup:    return .orange
        case .disk:       return .teal
        }
    }

    var label: String { rawValue }
}

// MARK: — ContentView

struct ContentView: View {
    @State private var selected: AppSection = .activity

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentPanel
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: — Sidebar

    var sidebar: some View {
        VStack(spacing: 0) {
            // App identity
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacGuard")
                        .font(.system(size: 13, weight: .bold))
                    Text("System Monitor")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            // Nav items
            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarItem(
                        section:  section,
                        isSelected: selected == section
                    )
                    .onTapGesture { selected = section }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Divider()
                .padding(.top, 8)

            // Bottom: version
            Text("MacGuard 1.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.vertical, 10)
        }
        .frame(width: 175)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: — Content panel

    @ViewBuilder
    var contentPanel: some View {
        switch selected {
        case .activity:
            ProcessMonitorView()
        case .uninstall:
            UninstallerView()
        case .loginItems:
            LoginItemsView()
        case .startup:
            StartupImpactView()
        case .disk:
            DiskAnalyzerView()
        }
    }
}

// MARK: — Sidebar Item

struct SidebarItem: View {
    let section:    AppSection
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? section.accentColor.opacity(0.18)
                          : (hovered ? Color.primary.opacity(0.06) : Color.clear))
                    .frame(width: 28, height: 28)
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? section.accentColor : .secondary)
            }

            Text(section.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)

            Spacer()

            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(section.accentColor)
                    .frame(width: 3, height: 16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? section.accentColor.opacity(0.08)
                      : (hovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: hovered)
    }
}
