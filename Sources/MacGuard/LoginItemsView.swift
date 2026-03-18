import SwiftUI
import AppKit

// MARK: — Filter

enum LoginItemFilter: String, CaseIterable {
    case all        = "All"
    case daemons    = "Daemons"
    case agents     = "Agents"
    case loginItems = "Login Items"
    case disabled   = "Disabled"

    var icon: String {
        switch self {
        case .all:        return "list.bullet"
        case .daemons:    return "gearshape.2.fill"
        case .agents:     return "gearshape.fill"
        case .loginItems: return "person.badge.clock.fill"
        case .disabled:   return "xmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .all:        return .primary
        case .daemons:    return .red
        case .agents:     return .orange
        case .loginItems: return .blue
        case .disabled:   return .gray
        }
    }
}

// MARK: — Main View

struct LoginItemsView: View {
    @StateObject private var manager      = LoginItemsManager()
    @State private var filter:  LoginItemFilter = .all
    @State private var search             = ""
    @State private var selected: LoginItem?
    @State private var pendingToggle: LoginItem?
    @State private var pendingRemove: LoginItem?
    @State private var resultMsg          = ""
    @State private var resultOK           = true
    @State private var showResult         = false

    var filtered: [LoginItem] {
        let base: [LoginItem]
        switch filter {
        case .all:        base = manager.items
        case .daemons:    base = manager.items.filter { $0.type == .launchDaemon }
        case .agents:     base = manager.items.filter { $0.type == .launchAgent  }
        case .loginItems: base = manager.items.filter { [.loginItem, .backgroundItem].contains($0.type) }
        case .disabled:   base = manager.items.filter { !$0.isEnabled }
        }
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter {
            $0.displayName.lowercased().contains(q)  ||
            $0.identifier.lowercased().contains(q)   ||
            $0.developerName.lowercased().contains(q)
        }
    }

    func count(_ f: LoginItemFilter) -> Int {
        switch f {
        case .all:        return manager.items.count
        case .daemons:    return manager.items.filter { $0.type == .launchDaemon }.count
        case .agents:     return manager.items.filter { $0.type == .launchAgent  }.count
        case .loginItems: return manager.items.filter { [.loginItem, .backgroundItem].contains($0.type) }.count
        case .disabled:   return manager.items.filter { !$0.isEnabled }.count
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 175, maxWidth: 195)
            content
        }
        .onAppear {
            // Only load once — onAppear fires on every tab switch in TabView
            if manager.items.isEmpty && !manager.isLoading { manager.refresh() }
            AdminSession.shared.warmUp { _ in }
        }
        .alert(resultOK ? "Done" : "Error", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: { Text(resultMsg) }
        // Disable confirmation
        .confirmationDialog(
            "Disable \(pendingToggle?.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingToggle != nil },
                set: { if !$0 { pendingToggle = nil } }
            ), titleVisibility: .visible
        ) {
            if let item = pendingToggle {
                Button("Disable", role: .destructive) {
                    manager.toggle(item) { ok, msg in
                        resultOK = ok; resultMsg = msg; showResult = true
                    }
                    pendingToggle = nil
                }
                Button("Cancel", role: .cancel) { pendingToggle = nil }
            }
        } message: {
            if let item = pendingToggle {
                Text("Disabling \(item.displayName) stops it from running at startup. You can re-enable it at any time.\(item.type.requiresAdmin ? "\n\n🔐 Your admin password will be required." : "")")
            }
        }
        // Remove confirmation
        .confirmationDialog(
            "Remove \(pendingRemove?.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ), titleVisibility: .visible
        ) {
            if let item = pendingRemove {
                Button("Remove Permanently", role: .destructive) {
                    manager.remove(item) { ok, msg in
                        resultOK = ok; resultMsg = msg; showResult = true
                    }
                    pendingRemove = nil
                }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            }
        } message: {
            if let item = pendingRemove {
                Text("This permanently deletes \(item.plistFileName). The service will no longer start at login.\(item.type.requiresAdmin ? "\n\n🔐 Your admin password will be required." : "")")
            }
        }
    }

    // MARK: — Sidebar
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Filter")
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            ForEach(LoginItemFilter.allCases, id: \.self) { f in
                FilterRow(
                    label: f.rawValue,
                    icon:  f.icon,
                    color: f.color,
                    count: count(f),
                    isSelected: filter == f
                )
                .onTapGesture { filter = f }
            }

            Spacer()

            if manager.isLoading {
                HStack { Spacer(); ProgressView().scaleEffect(0.65); Spacer() }
                    .padding(.bottom, 10)
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: — Content
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                TextField("Search name, identifier, developer…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { manager.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(manager.isLoading)
                Button { manager.openSystemSettings() } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.bordered)
                .help("Open System Settings → Login Items")
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 6)

            // FDA warning banner
            if manager.needsFDA && !manager.isLoading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Disk Access required for complete results")
                                .font(.system(size: 12, weight: .medium))
                            Text("Go to System Settings → Privacy & Security → Full Disk Access → enable MacGuard")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    // MacGuard runs in the menu bar — closing the window does NOT quit the
                    // process. Full Disk Access only takes effect on a fresh launch.
                    // The Relaunch button terminates and reopens the app properly.
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.orange).font(.system(size: 11))
                        Text("After granting access, you must fully relaunch MacGuard — closing the window is not enough.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Relaunch Now") {
                            let url = Bundle.main.bundleURL
                            let cfg = NSWorkspace.OpenConfiguration()
                            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                            NSApp.terminate(nil)
                        }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Status bar
            if !manager.statusMessage.isEmpty {
                Text(manager.statusMessage)
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }

            Divider()

            // List
            if manager.isLoading {
                Spacer()
                HStack { Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading background tasks…").foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                HStack { Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.35))
                        Text(search.isEmpty
                            ? "No items in this category"
                            : "No results for \"\(search)\"")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List(filtered, id: \.id, selection: $selected) { item in
                    LoginItemRow(
                        item:     item,
                        onToggle: {
                            if item.isEnabled { pendingToggle = item }
                            else {
                                manager.toggle(item) { ok, msg in
                                    resultOK = ok; resultMsg = msg; showResult = true
                                }
                            }
                        },
                        onReveal: { manager.revealInFinder(item)  },
                        onRemove: { pendingRemove = item          }
                    )
                    .tag(item)
                }
                .listStyle(.bordered)
            }
        }
    }
}

// MARK: — Filter Row
struct FilterRow: View {
    let label:      String
    let icon:       String
    let color:      Color
    let count:      Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(isSelected ? .white : color)
                .frame(width: 16)
            Text(label)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: — Item Row
struct LoginItemRow: View {
    let item:     LoginItem
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.type.color.opacity(0.1))
                    .frame(width: 42, height: 42)
                if let appURL = item.associatedApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().scaledToFit()
                        .frame(width: 32, height: 32)
                        .cornerRadius(6)
                } else {
                    Image(systemName: item.type.icon)
                        .font(.system(size: 18))
                        .foregroundColor(item.type.color)
                }
            }

            // Text info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .fontWeight(.medium)
                        .foregroundColor(item.isEnabled ? .primary : .secondary)
                    // Type badge
                    Text(item.type.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(item.type.color)
                        .cornerRadius(3)
                    // Admin badge
                    if item.type.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.7))
                            .help("Requires admin password to toggle")
                    }
                }
                Text(item.identifier)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.startupScope)
                        .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                    if !item.developerName.isEmpty {
                        Text("•").font(.caption2).foregroundColor(.secondary.opacity(0.5))
                        Text(item.developerName)
                            .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                    }
                }
            }

            Spacer()

            // Hover actions
            if hovered {
                HStack(spacing: 4) {
                    MiniButton("folder",    "Reveal in Finder",   .secondary, onReveal)
                    MiniButton("trash",     "Remove plist",       .red,       onRemove)
                }
                .transition(.opacity)
            }

            // Toggle
            VStack(alignment: .trailing, spacing: 3) {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(item.type.color)
                Text(item.isEnabled ? "Enabled" : "Disabled")
                    .font(.caption2)
                    .foregroundColor(item.isEnabled ? item.type.color : .secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}

struct MiniButton: View {
    let icon:    String
    let tooltip: String
    let color:   Color
    let action:  () -> Void
    init(_ icon: String, _ tooltip: String, _ color: Color, _ action: @escaping () -> Void) {
        self.icon = icon; self.tooltip = tooltip
        self.color = color; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12)).foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.1))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
