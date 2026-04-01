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
    @State private var searchText = ""
    @StateObject private var manager = LoginItemsManager()
    @State private var filter: LoginItemFilter = .all
    @State private var multiSelection = Set<LoginItem>()
    @State private var selectedItem: LoginItem? = nil
    @State private var isInspectorPresented = false
    
    // Toast & Banner states
    @State private var toastMessage = ""
    @State private var toastStyle: ToastStyle = .success
    @State private var showToast = false
    
    @State private var pendingToggle: LoginItem?
    @State private var pendingRemove: LoginItem?

    var filtered: [LoginItem] {
        let base: [LoginItem]
        switch filter {
        case .all:        base = manager.items
        case .daemons:    base = manager.items.filter { $0.type == .launchDaemon }
        case .agents:     base = manager.items.filter { $0.type == .launchAgent  }
        case .loginItems: base = manager.items.filter { [.loginItem, .backgroundItem].contains($0.type) }
        case .disabled:   base = manager.items.filter { !$0.isEnabled }
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.displayName.lowercased().contains(q)  ||
            $0.identifier.lowercased().contains(q)   ||
            $0.developerName.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                
                VStack(spacing: 0) {
                    toolbar
                    
                    if manager.needsFDA && !manager.isLoading {
                        fdaBanner.padding(12)
                    }
                    
                    mainList
                    
                    if !multiSelection.isEmpty {
                        batchActionsBar
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
                
                InspectorPane(title: "Item Details", isPresented: $isInspectorPresented) {
                    Group {
                        if let item = selectedItem {
                            LoginItemInspector(item: item)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            
            ToastView(message: toastMessage, style: toastStyle, isPresented: $showToast)
        }
        .onAppear {
            if manager.items.isEmpty && !manager.isLoading { manager.refresh() }
        }
    }

    private func showFeedback(_ msg: String, success: Bool) {
        toastMessage = msg
        toastStyle = success ? .success : .error
        withAnimation { showToast = true }
    }

    // MARK: - Components

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TYPES")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(LoginItemFilter.allCases, id: \.self) { f in
                SidebarRow(filter: f, current: filter, count: manager.count(f)) {
                    filter = f
                }
            }

            Spacer()
            
            if manager.isLoading {
                ProgressView().controlSize(.small).padding(16)
            }
        }
        .frame(width: 200)
        .background(.thinMaterial)
        .overlay(Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1), alignment: .trailing)
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(LoginItemFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            
            TextField("Search Login Items...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            
            Spacer()
            
            Button { manager.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(manager.isLoading)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var mainList: some View {
        List(filtered, selection: $multiSelection) { item in
            LoginItemRow(item: item) {
                selectedItem = item
                isInspectorPresented = true
            } onToggle: {
                if item.isEnabled { pendingToggle = item }
                else {
                    manager.toggle(item) { ok, msg in showFeedback(msg, success: ok) }
                }
            }
            .contextMenu {
                contextMenu(for: item)
            }
            .tag(item)
        }
        .listStyle(.inset)
    }

    private var batchActionsBar: some View {
        HStack {
            Text("\(multiSelection.count) items selected")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Disable Non-Apple") {
                manager.disableAllNonApple { count in
                    showFeedback("Disabled \(count) items", success: true)
                }
            }
            .buttonStyle(.bordered)
            Button("Export Selected") {
                manager.exportItems() // Simplified for now
            }
            .buttonStyle(.bordered)
            Button("Clear Selection") {
                multiSelection.removeAll()
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1), alignment: .top)
    }

    private var fdaBanner: some View {
        BannerView(
            title: "Full Disk Access Required",
            subtitle: "Grant access to see background items from all users.",
            style: .warning,
            actionLabel: "Open Settings",
            action: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        )
    }

    private func contextMenu(for item: LoginItem) -> some View {
        Group {
            Button("Inspect Details") {
                selectedItem = item
                withAnimation { isInspectorPresented = true }
            }
            Divider()
            Button("Reveal in Finder") { manager.revealInFinder(item) }
            if item.associatedApp != nil {
                Button("Reveal App in Finder") { manager.revealAppInFinder(item) }
            }
            Divider()
            Button("Remove...") { pendingRemove = item }
        }
    }
}

// MARK: - Subviews

struct SidebarRow: View {
    let filter: LoginItemFilter
    let current: LoginItemFilter
    let count: Int
    let action: () -> Void
    
    var isSelected: Bool { filter == current }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: filter.icon)
                .foregroundColor(isSelected ? .accentColor : filter.color)
                .frame(width: 16)
            Text(filter.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct LoginItemRow: View {
    let item: LoginItem
    let onSelect: () -> Void
    let onToggle: () -> Void
    @State private var hovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(item.type.color.opacity(0.1))
                    .frame(width: 40, height: 40)
                if let appURL = item.associatedApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().scaledToFit().frame(width: 30, height: 30)
                } else {
                    Image(systemName: item.type.icon).foregroundColor(item.type.color)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.displayName).fontWeight(.medium)
                    if item.type.requiresAdmin {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                Text(item.identifier).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            
            Spacer()
            
            if hovered {
                Button(action: onSelect) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Toggle("", isOn: Binding(get: { item.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 4)
        .onHover { hovered = $0 }
    }
}

struct LoginItemInspector: View {
    let item: LoginItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            
            Section(header: Text("Details").font(.caption.bold())) {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow(label: "Identifier", value: item.identifier)
                    InfoRow(label: "Type", value: item.type.displayName)
                    InfoRow(label: "Scope", value: item.startupScope)
                }
            }
            
            if !item.developerName.isEmpty {
                Section(header: Text("Developer").font(.caption.bold())) {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(label: "Name", value: item.developerName)
                        InfoRow(label: "Team ID", value: item.developerID)
                    }
                }
            }
            
            if let plist = item.plistURL {
                Section(header: Text("Location").font(.caption.bold())) {
                    Text(plist.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                }
            }
            
            Spacer()
        }
    }
    
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.type.color.opacity(0.1))
                    .frame(width: 56, height: 56)
                if let appURL = item.associatedApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().scaledToFit().frame(width: 40, height: 40)
                } else {
                    Image(systemName: item.type.icon).font(.system(size: 24)).foregroundColor(item.type.color)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.headline)
                Text(item.isEnabled ? "Enabled" : "Disabled")
                    .font(.caption.bold())
                    .foregroundColor(item.isEnabled ? item.type.color : .secondary)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11)).foregroundColor(.primary).textSelection(.enabled)
        }
    }
}

extension LoginItemsManager {
    func count(_ f: LoginItemFilter) -> Int {
        switch f {
        case .all:        return items.count
        case .daemons:    return items.filter { $0.type == .launchDaemon }.count
        case .agents:     return items.filter { $0.type == .launchAgent  }.count
        case .loginItems: return items.filter { [.loginItem, .backgroundItem].contains($0.type) }.count
        case .disabled:   return items.filter { !$0.isEnabled }.count
        }
    }
}

#Preview {
    LoginItemsView()
        .frame(width: 800, height: 600)
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
