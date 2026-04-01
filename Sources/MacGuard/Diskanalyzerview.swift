import SwiftUI
import AppKit

struct DiskAnalyzerView: View {
    @State private var searchText = ""
    @StateObject private var analyzer      = DiskAnalyzer()
    @StateObject private var cleanupEngine = CleanupEngine()
    @State private var showFilePicker      = false
    @State private var showCleanup         = false
    @State private var hoveredID:          UUID?
    @State private var selectedItem:       DiskItem?
    @State private var showInspector       = false
    @State private var shimmer             = false

    private let chartLimit = 12

    var showContent: Bool { !analyzer.items.isEmpty }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                
                ScrollView {
                    VStack(spacing: 24) {
                        if let root = analyzer.rootURL {
                            volumeVaultHero(for: root)
                        } else {
                            welcomeHero
                        }
                        
                        if showContent {
                            HStack(alignment: .top, spacing: 20) {
                                chartPanel
                                    .frame(maxWidth: .infinity)
                                listPanel
                                    .frame(width: 380)
                            }
                        } else if analyzer.isScanning {
                            scanningState
                        } else {
                            emptyState
                        }
                    }
                    .padding(24)
                }
            }
            .blur(radius: showInspector ? 2 : 0)
            
            InspectorPane(title: "Disk Item Details", isPresented: $showInspector) {
                Group {
                    if let item = selectedItem {
                        DiskItemInspector(item: item) {
                            analyzer.drillDown(into: item)
                            showInspector = false
                        }
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                analyzer.scan(url)
            }
        }
        .sheet(isPresented: $showCleanup) {
            CleanupView(engine: cleanupEngine) {
                showCleanup = false
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            breadcrumbOrTitle
            
            Spacer()
            
            if analyzer.isScanning {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: analyzer.scanProgress)
                        .frame(width: 120)
                        .tint(.teal)
                    Text(analyzer.progress)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Button("Cancel") { analyzer.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            
            if !analyzer.isScanning && !analyzer.items.isEmpty {
                Button {
                    cleanupEngine.analyse(
                        rootURL:  analyzer.rootURL ?? FileManager.default.homeDirectoryForCurrentUser,
                        allItems: analyzer.items,
                        apiKey:   SettingsManager.shared.anthropicApiKey
                    )
                    showCleanup = true
                } label: {
                    Label("Smart Cleanup", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.teal)
            }

            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Choose Folder")

            locationMenu
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var locationMenu: some View {
        Menu {
            Button("Home Folder") { analyzer.scan(FileManager.default.homeDirectoryForCurrentUser) }
            Button("Downloads") { analyzer.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
            Button("Documents") { analyzer.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
            Divider()
            Button("/Applications") { analyzer.scan(URL(fileURLWithPath: "/Applications")) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
    }

    private var breadcrumbOrTitle: some View {
        Group {
            if analyzer.breadcrumbs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.teal)
                    Text("Disk Analyzer")
                        .font(.system(size: 20, weight: .bold))
                }
            } else {
                BreadcrumbBar(
                    breadcrumbs: analyzer.breadcrumbs,
                    onNavigate:  { analyzer.navigateTo(breadcrumb: $0) },
                    onBack:      {
                        let crumbs = analyzer.breadcrumbs
                        if crumbs.count > 1 {
                            analyzer.navigateTo(breadcrumb: crumbs[crumbs.count - 2])
                        }
                    }
                )
            }
        }
    }

    // MARK: - Vault Hero

    private func volumeVaultHero(for url: URL) -> some View {
        let attrs   = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        let total   = attrs?[.systemSize]     as? Int64 ?? 1
        let free    = attrs?[.systemFreeSize] as? Int64 ?? 0
        let used    = total - free
        let pctUsed = Double(used) / Double(max(1, total))
        let pctThis = analyzer.totalSize > 0 ? Double(analyzer.totalSize) / Double(max(1, total)) : 0.0

        return VStack(spacing: 20) {
            HStack(spacing: 32) {
                // Main Gauge
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: pctUsed)
                        .stroke(
                            AngularGradient(colors: [.teal, .blue, .purple], center: .center),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: .teal.opacity(0.3), radius: 5)
                    
                    VStack(spacing: 2) {
                        Text("\(Int(pctUsed * 100))%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("TOTAL USED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 24, weight: .bold))
                        Text(url.path)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 20) {
                        VaultStat(label: "FOLDER SIZE", value: DiskItem.formatSize(analyzer.totalSize), color: .teal)
                        VaultStat(label: "AVAILABLE", value: DiskItem.formatSize(free), color: .blue)
                    }
                }
                
                Spacer()
                
                // Active Scan Glow
                if analyzer.isScanning {
                    Circle()
                        .fill(Color.teal)
                        .frame(width: 8, height: 8)
                        .shadow(color: .teal, radius: 10)
                        .opacity(shimmer ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: shimmer)
                }
            }
            
            // Usage Bar
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                        
                        // Other Used
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: geo.size.width * CGFloat(pctUsed))
                        
                        // Current Folder
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: geo.size.width * CGFloat(pctThis))
                            .shadow(color: .teal.opacity(0.4), radius: 4)
                    }
                }
                .frame(height: 12)
                
                HStack(spacing: 16) {
                    LegendDot(color: .teal, label: "Current Folder")
                    LegendDot(color: .primary.opacity(0.2), label: "Other Used")
                    LegendDot(color: .primary.opacity(0.05), label: "Free Space")
                }
            }
        }
        .padding(32)
        .background(.regularMaterial)
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var welcomeHero: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: .teal.opacity(0.3), radius: 20)
            
            Text("Analyze Disk Usage")
                .font(.system(size: 32, weight: .bold))
            
            Text("Select a folder to reveal its contents and reclaim your space.")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            
            Button {
                showFilePicker = true
            } label: {
                Text("Select Folder")
                    .font(.headline)
                    .frame(width: 200, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Panels

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MAJOR CONTRIBUTIONS")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .kerning(1)
            
            VStack(spacing: 12) {
                let realItems = analyzer.items.filter { !$0.isPending }
                let maxSize = realItems.first?.size ?? 1
                let chartItems = Array(analyzer.items.prefix(chartLimit))
                
                ForEach(chartItems) { item in
                    ModernChartBar(
                        item: item,
                        maxSize: maxSize,
                        total: analyzer.totalSize,
                        isHovered: hoveredID == item.id,
                        shimmer: shimmer
                    ) {
                        selectedItem = item
                        showInspector = true
                    }
                    .onHover { hoveredID = $0 ? item.id : nil }
                }
                
                if analyzer.items.count > chartLimit {
                    let otherItems = analyzer.items.dropFirst(chartLimit).filter { !$0.isPending }
                    let otherSize = otherItems.reduce(0) { $0 + $1.size }
                    if otherSize > 0 {
                        OtherBar(size: otherSize, total: analyzer.totalSize, count: otherItems.count)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ALL ITEMS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .kerning(1)
                Spacer()
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            
            VStack(spacing: 0) {
                let displayed = analyzer.items.filter { item in
                    guard !searchText.isEmpty else { return true }
                    return item.name.lowercased().contains(searchText.lowercased())
                }
                
                ForEach(displayed.prefix(50)) { item in
                    DiskItemRow(item: item, total: analyzer.totalSize)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedItem = item
                            showInspector = true
                        }
                    
                    if item.id != displayed.prefix(50).last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning structure...")
                .font(.system(size: 20, weight: .bold))
            Text(analyzer.progress)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.1))
            Text("No content found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
}

private struct VaultStat: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }
}

private struct ModernChartBar: View {
    let item: DiskItem
    let maxSize: Int64
    let total: Int64
    let isHovered: Bool
    let shimmer: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ChartBar(item: item, maxSize: maxSize, total: total, isHovered: isHovered, shimmer: shimmer)
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Chart Bar

struct ChartBar: View {
    let item:      DiskItem
    let maxSize:   Int64
    let total:     Int64
    let isHovered: Bool
    let shimmer:   Bool   // external toggle that drives pending animation

    private var fraction: Double {
        guard maxSize > 0, !item.isPending else { return 0 }
        return min(1.0, Double(item.size) / Double(maxSize))
    }

    private var pctOfTotal: Double {
        guard total > 0, !item.isPending else { return 0 }
        return Double(item.size) / Double(total) * 100.0
    }

    private var barColor: Color {
        if item.isPending { return .secondary }
        if item.isPackage { return .blue }
        if item.isDir     { return .teal }
        return .teal.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: item.isPending ? "hourglass" : item.icon)
                .font(.system(size: 11))
                .foregroundColor(item.isPending ? .secondary : barColor)
                .frame(width: 14)

            // Name
            Text(item.name)
                .font(.system(size: 11))
                .foregroundColor(item.isPending ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor.opacity(0.1))

                    if item.isPending {
                        // Shimmer — width pulses using external shimmer bool
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: geo.size.width * (shimmer ? 0.45 : 0.15))
                            .animation(
                                .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                                value: shimmer
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor.opacity(isHovered ? 0.8 : 0.55))
                            .frame(width: geo.size.width * CGFloat(fraction))
                            .animation(.easeOut(duration: 0.4), value: fraction)
                    }
                }
            }
            .frame(height: 16)

            // Size + percent
            HStack(spacing: 4) {
                if item.isPending {
                    Text("sizing…")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 62, alignment: .trailing)
                } else {
                    Text(item.sizeLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(width: 62, alignment: .trailing)
                }
                Text(item.isPending ? "" : String(format: "%.1f%%", pctOfTotal))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Drill-down chevron
            if item.isDir && !item.isPackage && !item.isPending {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(isHovered ? .teal : .secondary.opacity(0.4))
            } else {
                Spacer().frame(width: 12)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered && !item.isPending ? barColor.opacity(0.06) : Color.clear)
        )
        .cursor(item.isDir && !item.isPackage && !item.isPending ? .pointingHand : .arrow)
    }
}

// MARK: — Pending Summary Bar (replaces individual pending bars in chart)

struct PendingSummaryBar: View {
    let count:   Int
    let shimmer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14)

            Text("\(count) folder\(count == 1 ? "" : "s") sizing…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(shimmer ? 0.22 : 0.1))
                        .frame(width: geo.size.width * (shimmer ? 0.6 : 0.2))
                        .animation(
                            .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                            value: shimmer
                        )
                }
            }
            .frame(height: 16)

            Spacer()
                .frame(width: 100)   // aligns with size/percent columns
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }
}

// MARK: — Other Bar

struct OtherBar: View {
    let size:  Int64
    let total: Int64
    let count: Int

    private var pct: Double {
        guard total > 0, size > 0 else { return 0 }
        return Double(size) / Double(total) * 100.0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text("+ \(count) more")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: geo.size.width *
                               CGFloat(min(1.0, Double(max(0, size)) / Double(max(1, total)))))
                }
            }
            .frame(height: 16)
            HStack(spacing: 4) {
                Text(DiskItem.formatSize(size))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .trailing)
                Text(String(format: "%.1f%%", pct))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            Spacer().frame(width: 12)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }
}

// MARK: — List Row

struct DiskItemRow: View {
    let item:  DiskItem
    let total: Int64

    private var pctOfTotal: Double {
        guard total > 0, item.size > 0 else { return 0 }
        return Double(item.size) / Double(total) * 100.0
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconColor.opacity(item.isPending ? 0.05 : 0.1))
                    .frame(width: 30, height: 30)
                Image(systemName: item.isPending ? "hourglass" : item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(item.isPending ? .secondary : iconColor)
            }

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(item.isPending ? .secondary : .primary)

                Group {
                    if item.isPending {
                        Text("Calculating size…")
                    } else if item.isDir && !item.isPackage {
                        Text(item.itemCount >= 0
                             ? "\(item.itemCount) item\(item.itemCount == 1 ? "" : "s")"
                             : "Folder")
                    } else {
                        Text(item.url.pathExtension.isEmpty
                             ? "File"
                             : item.url.pathExtension.uppercased() + " file")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Drill-down chevron for ready folders
            if item.isDir && !item.isPackage && !item.isPending {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.4))
            }

            // Size column
            VStack(alignment: .trailing, spacing: 2) {
                if item.isPending {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Text(item.sizeLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(String(format: "%.1f%%", pctOfTotal))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(item.isPending ? 0.65 : 1.0)
    }

    private var iconColor: Color {
        if item.isSymlink { return .gray }
        if item.isPackage { return .blue }
        if item.isDir     { return .teal }
        let ext = item.url.pathExtension.lowercased()
        switch ext {
        case "jpg","jpeg","png","gif","webp","heic": return .pink
        case "mp4","mov","avi","mkv","m4v":          return .purple
        case "mp3","m4a","aac","flac","wav":         return .indigo
        case "pdf":                                   return .red
        case "zip","tar","gz","bz2","dmg","rar":     return .orange
        default:                                      return .teal
        }
    }
}

// MARK: — Breadcrumb Bar

struct BreadcrumbBar: View {
    let breadcrumbs: [URL]
    let onNavigate:  (URL) -> Void
    let onBack:      () -> Void

    // Only show last 4 crumbs max — truncate from the left with "…"
    private let maxVisible = 4

    private var visibleCrumbs: [URL] {
        if breadcrumbs.count <= maxVisible {
            return breadcrumbs
        }
        return Array(breadcrumbs.suffix(maxVisible))
    }

    private var isTruncated: Bool { breadcrumbs.count > maxVisible }
    private var canGoBack:   Bool { breadcrumbs.count > 1 }

    var body: some View {
        HStack(spacing: 6) {
            // Back button — only when drilled in
            if canGoBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.teal)
                        .frame(width: 24, height: 24)
                        .background(Color.teal.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Go up one level")
            }

            // Pill container for the path
            HStack(spacing: 0) {
                // Truncation indicator
                if isTruncated {
                    Button {
                        // Navigate to the last hidden crumb (one before visible range)
                        let hiddenIdx = breadcrumbs.count - maxVisible - 1
                        if hiddenIdx >= 0 {
                            onNavigate(breadcrumbs[hiddenIdx])
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to parent folder")

                    SeparatorChevron()
                }

                // Visible crumbs
                ForEach(Array(visibleCrumbs.enumerated()), id: \.element) { idx, url in
                    let isFirst   = idx == 0 && !isTruncated
                    let isLast    = idx == visibleCrumbs.count - 1
                    let globalIdx = breadcrumbs.firstIndex(of: url) ?? idx

                    if idx > 0 { SeparatorChevron() }

                    CrumbPill(
                        url:      url,
                        isFirst:  isFirst,
                        isRoot:   globalIdx == 0,
                        isLast:   isLast,
                        onTap:    { if !isLast { onNavigate(url) } }
                    )
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// Single crumb pill

struct CrumbPill: View {
    let url:     URL
    let isFirst: Bool
    let isRoot:  Bool
    let isLast:  Bool
    let onTap:   () -> Void

    @State private var hovered = false

    // Root folder gets a folder icon, all others just the name
    private var label: String {
        isRoot ? url.lastPathComponent : url.lastPathComponent
    }

    private var icon: String {
        isRoot ? "folder.fill" : "chevron.right"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isRoot {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isLast ? .primary : .teal)
                }

                Text(label)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                    .foregroundColor(isLast ? .primary : (hovered ? .teal : .secondary))
                    .lineLimit(1)
                    .fixedSize()    // never truncate individual crumb name
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered && !isLast
                          ? Color.teal.opacity(0.1)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLast)   // current location — not tappable
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .help(isLast ? url.path : "Navigate to \(url.lastPathComponent)")
    }
}

// Separator between crumbs

struct SeparatorChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(Color.primary.opacity(0.2))
            .padding(.horizontal, 1)
    }
}

// MARK: — Helpers

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
