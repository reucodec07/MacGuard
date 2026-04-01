import SwiftUI

// MARK: — Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case activity  = "Activity"
    case uninstall = "Uninstaller"
    case loginItems = "Login Items"
    case startup   = "Startup"
    case disk      = "Disk"
    case settings  = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .activity:   return "cpu"
        case .uninstall:  return "trash"
        case .loginItems: return "person.badge.clock"
        case .startup:    return "bolt"
        case .disk:       return "internaldrive"
        case .settings:   return "gearshape"
        }
    }

    var accentColor: Color {
        switch self {
        case .activity:   return .blue
        case .uninstall:  return .red
        case .loginItems: return .indigo
        case .startup:    return .orange
        case .disk:       return .teal
        case .settings:   return .gray
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
                .frame(width: 240)
            
            Divider()
            
            contentPanel(for: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            
            List(selection: $selected) {
                ForEach(AppSection.allCases) { section in
                    SidebarItem(section: section, isSelected: selected == section)
                        .tag(section)
                        .onTapGesture { selected = section }
                }
            }
            .listStyle(.sidebar)
            
            Spacer()
            
            footer
        }
        .background(.thinMaterial)
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 0) {
                Text("MacGuard")
                    .font(.system(size: 15, weight: .bold))
                Text("System Sentinel")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().padding(.horizontal, 16)
            Text("MacGuard v1.0")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.bottom, 16)
        }
    }

    // MARK: - Content panel

    @ViewBuilder
    private func contentPanel(for section: AppSection) -> some View {
        switch section {
        case .activity:   ProcessMonitorView()
        case .uninstall:  UninstallerView()
        case .loginItems: LoginItemsView()
        case .startup:    StartupImpactView()
        case .disk:       DiskAnalyzerView()
        case .settings:   SettingsView()
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
