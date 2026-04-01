import SwiftUI
import AppKit

struct CleanupView: View {
    @ObservedObject var engine: CleanupEngine
    let onDone: () -> Void

    @State private var selectedCategory:    CleanupCategory? = nil
    @State private var hoveredID:           UUID?
    @State private var showConfirm          = false
    @State private var showPermanentConfirm = false
    @State private var permanentConfirmText = ""
    @State private var resultMessage:       String?
    @State private var resultSuccess        = true

    var filteredSuggestions: [CleanupItem] {
        guard let cat = selectedCategory else { return engine.suggestions }
        return engine.suggestions.filter { $0.category == cat }
    }

    var categories: [(CleanupCategory, Int, Int64)] {
        CleanupCategory.allCases.compactMap { cat in
            let items = engine.suggestions.filter { $0.category == cat }
            guard !items.isEmpty else { return nil }
            return (cat, items.count, items.reduce(0) { $0 + $1.size })
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                sheetHeader
                
                if engine.isAnalysing {
                    analysingState
                } else if engine.suggestions.isEmpty {
                    nothingFoundState
                } else {
                    mainContent
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .alert(resultSuccess ? "Done" : "Error", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") {
                resultMessage = nil
                if resultSuccess { onDone() }
            }
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog("Move to Trash?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Move \(engine.stagedSizeLabel) to Trash", role: .destructive) {
                engine.moveToTrash { count, freed, err in
                    if let err { resultMessage = err; resultSuccess = false }
                    else { resultMessage = "✅ Moved \(count) items to Trash (\(DiskItem.formatSize(freed)) freed)"; resultSuccess = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items remain in Trash for manual recovery if needed.")
        }
        .sheet(isPresented: $showPermanentConfirm) {
            PermanentDeleteConfirmSheet(
                eligibleItems:  engine.permanentDeleteEligible,
                totalSize:      engine.permanentDeleteSizeLabel,
                confirmText:    $permanentConfirmText,
                onConfirm: {
                    showPermanentConfirm = false
                    engine.permanentDelete { count, freed, err in
                        if let err { resultMessage = err; resultSuccess = false }
                        else { resultMessage = "🗑 Permanently deleted \(count) items (\(DiskItem.formatSize(freed)) freed)"; resultSuccess = true }
                    }
                },
                onCancel: { showPermanentConfirm = false }
            )
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if engine.isAIEnhancing { aiBanner }
            if let summary = engine.aiSummary { aiSummaryBanner(summary) }
            
            HStack(spacing: 0) {
                // Suggestions Panel
                VStack(spacing: 0) {
                    categoryTabs
                        .padding(.vertical, 16)
                    
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredSuggestions) { item in
                                SuggestionRowView(
                                    item:      item,
                                    isStaged:  engine.staged.contains(item),
                                    isHovered: hoveredID == item.id,
                                    onToggle:  { engine.toggleStage(item) }
                                )
                                .onHover { hoveredID = $0 ? item.id : nil }
                                
                                if item.id != filteredSuggestions.last?.id {
                                    Divider().padding(.leading, 72).opacity(0.3)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                
                // Summary & Actions Panel
                VStack(spacing: 0) {
                    stagingTray
                    Divider()
                    summaryPanel
                }
                .frame(width: 320)
                .background(.thinMaterial)
            }
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.teal.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: "wand.and.sparkles")
                    .foregroundColor(.teal)
                    .font(.system(size: 20))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Cleanup")
                    .font(.system(size: 20, weight: .bold))
                Text("Suggested items safe to remove")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Done") { onDone() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                CategoryTab(label: "All", count: engine.suggestions.count, size: engine.suggestions.reduce(0) { $0 + $1.size }, color: .teal, isSelected: selectedCategory == nil) { selectedCategory = nil }
                
                ForEach(categories, id: \.0) { cat, count, size in
                    CategoryTab(label: cat.rawValue, count: count, size: size, color: colorFor(cat), isSelected: selectedCategory == cat) { selectedCategory = cat }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var stagingTray: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("STAGED FOR REMOVAL")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .kerning(1)
                Spacer()
                if !engine.staged.isEmpty {
                    Button("Clear All") { engine.unstageAll() }
                        .font(.system(size: 11, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                }
            }
            
            if engine.staged.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.1))
                    Text("Select items to stage them.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(engine.staged) { item in
                            StagedRow(item: item) { engine.unstage(item) }
                            if item.id != engine.staged.last?.id {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
    }

    private var summaryPanel: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Potential Savings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(alignment: .bottom, spacing: 4) {
                    Text(engine.stagedSizeLabel)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.teal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                Button {
                    showConfirm = true
                } label: {
                    HStack {
                        if engine.isDeleting { ProgressView().scaleEffect(0.6) }
                        else { Image(systemName: "trash.fill") }
                        Text("Move Items to Trash")
                            .fontWeight(.bold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(engine.staged.isEmpty || engine.isDeleting)
                
                if !engine.permanentDeleteEligible.isEmpty {
                    Button {
                        permanentConfirmText = ""
                        showPermanentConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "bolt.slash.fill")
                            Text("Permanent Delete")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
                }
            }
            
            // Safety Note
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.checkered")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
                Text("Trashed items are moved to your macOS Trash and can be recovered manually.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
    }

    private var aiBanner: some View {
        HStack(spacing: 12) {
            ProgressView().scaleEffect(0.6)
            Text("Claude is analyzing items for deeper safety insights...")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.purple)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.purple.opacity(0.05))
    }

    private func aiSummaryBanner(_ summary: String) -> some View {
        let isError = summary.hasPrefix("⚠️")
        return HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundColor(isError ? .orange : .purple)
                .font(.system(size: 14))
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isError ? .orange : .primary)
            Spacer()
            if !isError {
                Text("AI REVIEWED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(isError ? Color.orange.opacity(0.08) : Color.purple.opacity(0.08))
    }

    private var analysingState: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning for junk...")
                .font(.system(size: 20, weight: .bold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nothingFoundState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundColor(.teal.opacity(0.2))
            Text("Folder is clean!")
                .font(.system(size: 20, weight: .bold))
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colorFor(_ cat: CleanupCategory) -> Color {
        switch cat {
        case .cache:      return .blue
        case .log:        return .teal
        case .temp:       return .gray
        case .download:   return .orange
        case .largeMedia: return .purple
        case .appData:    return .red
        case .userFile:   return .indigo
        case .unknown:    return .secondary
        }
    }
}

private struct SuggestionRowView: View {
    let item: CleanupItem
    let isStaged: Bool
    let isHovered: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                        .frame(width: 20, height: 20)
                    if isStaged {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.teal)
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(safetyColor.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: item.safety.icon)
                        .foregroundColor(safetyColor)
                        .font(.system(size: 18))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .bold))
                    Text(item.reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.sizeLabel)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    
                    HStack(spacing: 6) {
                        Text(item.category.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                        
                        Text("\(item.confidence)%")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(confidenceColor)
                    }
                }
            }
            .padding(16)
            .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        }
        .buttonStyle(.plain)
    }
    
    private var safetyColor: Color {
        switch item.safety {
        case .safe: return .green
        case .caution: return .orange
        case .review: return .red
        }
    }
    
    private var confidenceColor: Color {
        if item.confidence >= 90 { return .green }
        if item.confidence >= 70 { return .teal }
        if item.confidence >= 50 { return .orange }
        return .red
    }
}

private struct StagedRow: View {
    let item: CleanupItem
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: item.safety.icon)
                .foregroundColor(item.safety == .safe ? .green : (item.safety == .caution ? .orange : .red))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.sizeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
}

private struct CategoryTab: View {
    let label: String
    let count: Int
    let size: Int64
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                
                HStack(alignment: .bottom, spacing: 4) {
                    Text(DiskItem.formatSize(size))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? color.opacity(0.15) : Color.primary.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PermanentDeleteConfirmSheet: View {
    let eligibleItems: [CleanupItem]
    let totalSize: String
    @Binding var confirmText: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
            VStack(spacing: 8) {
                Text("Permanent Delete")
                    .font(.system(size: 20, weight: .bold))
                Text("This action is irreversible. \(eligibleItems.count) items (\(totalSize)) will be destroyed immediately.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Type 'DELETE' to confirm:")
                    .font(.system(size: 11, weight: .bold))
                TextField("", text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                
                Button("Delete Forever", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(confirmText != "DELETE")
            }
        }
        .padding(40)
        .frame(width: 400)
    }
}
