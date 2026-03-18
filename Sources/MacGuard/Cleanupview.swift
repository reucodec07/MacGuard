import SwiftUI
import AppKit

// MARK: — Cleanup Sheet
// Presented as a sheet over the Disk Analyzer after a scan completes.
// Three columns: Suggestions | Staged (staging tray) | Summary

struct CleanupView: View {
    @ObservedObject var engine: CleanupEngine
    let onDone: () -> Void

    // Paste your Anthropic API key here, or load from Keychain/env in production
    @State private var apiKey:              String = ""
    @State private var showAPIKeyEntry      = false
    @State private var selectedCategory:    CleanupCategory? = nil
    @State private var hoveredID:           UUID?
    @State private var showConfirm          = false
    @State private var showPermanentConfirm = false
    @State private var permanentConfirmText = ""   // user must type "DELETE"
    @State private var resultMessage:       String?
    @State private var resultSuccess        = true

    // Filter suggestions by selected category tab
    var filteredSuggestions: [CleanupItem] {
        guard let cat = selectedCategory else { return engine.suggestions }
        return engine.suggestions.filter { $0.category == cat }
    }

    // Category counts for the tab bar
    var categories: [(CleanupCategory, Int, Int64)] {
        CleanupCategory.allCases.compactMap { cat in
            let items = engine.suggestions.filter { $0.category == cat }
            guard !items.isEmpty else { return nil }
            return (cat, items.count, items.reduce(0) { $0 + $1.size })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            if engine.isAnalysing {
                analysingState
            } else if engine.suggestions.isEmpty {
                nothingFoundState
            } else {
                // AI enhancement banner — shown while Haiku is reviewing
                if engine.isAIEnhancing {
                    aiBanner
                }

                // AI summary — shown after Haiku completes
                if let summary = engine.aiSummary {
                    aiSummaryBanner(summary)
                }
                HStack(spacing: 0) {
                    // Left: suggestions list
                    suggestionsList
                        .frame(minWidth: 340, idealWidth: 380)

                    Divider()

                    // Right: staging tray + summary
                    VStack(spacing: 0) {
                        stagingTray
                        Divider()
                        summaryPanel
                    }
                    .frame(minWidth: 280, idealWidth: 300)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .alert(resultSuccess ? "Done" : "Error",
               isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
               )
        ) {
            Button("OK") {
                resultMessage = nil
                if resultSuccess { onDone() }
            }
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog(
            "Move \(engine.staged.count) item(s) to Trash?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Move \(engine.stagedSizeLabel) to Trash", role: .destructive) {
                engine.moveToTrash { count, freed, err in
                    if let err {
                        resultMessage = err
                        resultSuccess = false
                    } else {
                        resultMessage = "✅ Moved \(count) item(s) to Trash · \(DiskItem.formatSize(freed)) freed\n\nItems are in your Trash — you can recover them any time."
                        resultSuccess = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves items to your Trash — nothing is permanently deleted. You can recover anything from Trash if needed.")
        }
        // Two-step permanent delete confirmation — user must type "DELETE"
        .sheet(isPresented: $showPermanentConfirm) {
            PermanentDeleteConfirmSheet(
                eligibleItems:  engine.permanentDeleteEligible,
                totalSize:      engine.permanentDeleteSizeLabel,
                confirmText:    $permanentConfirmText,
                onConfirm: {
                    showPermanentConfirm = false
                    engine.permanentDelete { count, freed, err in
                        if let err {
                            resultMessage = err
                            resultSuccess = false
                        } else {
                            resultMessage = "🗑 Permanently deleted \(count) item(s) · \(DiskItem.formatSize(freed)) freed"
                            resultSuccess = true
                        }
                    }
                },
                onCancel: { showPermanentConfirm = false }
            )
        }
    }

    // MARK: — Header

    var sheetHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(.teal)
                    Text("Smart Cleanup")
                        .font(.system(size: 16, weight: .bold))
                }
                Text("Items are moved to Trash — nothing is permanently deleted.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Done") { onDone() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: — Suggestions list (left panel)

    var suggestionsList: some View {
        VStack(spacing: 0) {
            // Category filter tabs
            if !categories.isEmpty {
                categoryTabs
                Divider()
            }

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSuggestions) { item in
                        SuggestionRow(
                            item:      item,
                            isStaged:  engine.staged.contains(item),
                            isHovered: hoveredID == item.id,
                            onToggle:  { engine.toggleStage(item) }
                        )
                        .onHover { hoveredID = $0 ? item.id : nil }

                        if item.id != filteredSuggestions.last?.id {
                            Divider()
                                .padding(.leading, 48)
                                .opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // "All" tab
                CategoryTab(
                    label: "All",
                    count: engine.suggestions.count,
                    size:  engine.suggestions.reduce(0) { $0 + $1.size },
                    color: .teal,
                    isSelected: selectedCategory == nil,
                    onTap: { selectedCategory = nil }
                )

                ForEach(categories, id: \.0) { cat, count, size in
                    CategoryTab(
                        label: cat.rawValue,
                        count: count,
                        size:  size,
                        color: colorFor(cat),
                        isSelected: selectedCategory == cat,
                        onTap: { selectedCategory = cat }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    // MARK: — Staging tray (right top)

    var stagingTray: some View {
        VStack(spacing: 0) {
            // Tray header
            HStack {
                Text("STAGED FOR REMOVAL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .kerning(0.5)
                Spacer()
                if !engine.staged.isEmpty {
                    Button("Clear all") { engine.unstageAll() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if engine.staged.isEmpty {
                // Empty tray placeholder
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.25))
                    Text("Tap items on the left\nto stage them for removal")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(engine.staged) { item in
                            StagedRow(
                                item:     item,
                                onRemove: { engine.unstage(item) }
                            )
                            if item.id != engine.staged.last?.id {
                                Divider()
                                    .padding(.leading, 14)
                                    .opacity(0.4)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: — Summary panel (right bottom)

    var summaryPanel: some View {
        VStack(spacing: 0) {
            // Safety breakdown
            VStack(spacing: 8) {
                // Space to recover
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Space to recover")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(engine.stagedSizeLabel)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.teal)
                    }
                    Spacer()

                    // Overall safety badge
                    if !engine.staged.isEmpty {
                        VStack(spacing: 3) {
                            Image(systemName: engine.overallSafety.icon)
                                .font(.system(size: 20))
                                .foregroundColor(safetyColor(engine.overallSafety))
                            Text(engine.overallSafety.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(safetyColor(engine.overallSafety))
                        }
                    }
                }

                // Breakdown pills
                if !engine.staged.isEmpty {
                    HStack(spacing: 6) {
                        if engine.stagedSafeCount > 0 {
                            SafetyPill(count: engine.stagedSafeCount,
                                       label: "safe",
                                       color: .green)
                        }
                        if engine.stagedCautionCount > 0 {
                            SafetyPill(count: engine.stagedCautionCount,
                                       label: "review",
                                       color: .orange)
                        }
                        if engine.stagedReviewCount > 0 {
                            SafetyPill(count: engine.stagedReviewCount,
                                       label: "careful",
                                       color: .red)
                        }
                        Spacer()
                    }
                }

                // Quick-add buttons
                HStack(spacing: 6) {
                    Button {
                        engine.stageAll(safety: .safe)
                    } label: {
                        Label("Add all safe", systemImage: "checkmark.shield")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)

                    Spacer()
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 8) {
                // ── Move to Trash (always available) ─────────
                Button {
                    guard !engine.staged.isEmpty else { return }
                    showConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        if engine.isDeleting {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                        }
                        Text(engine.staged.isEmpty
                             ? "Nothing staged"
                             : "Move \(engine.stagedSizeLabel) to Trash")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.staged.isEmpty ? .secondary : trashButtonColor)
                .disabled(engine.staged.isEmpty || engine.isDeleting)

                // ── Permanently Delete (only high-confidence items) ──
                if !engine.permanentDeleteEligible.isEmpty {
                    Button {
                        permanentConfirmText = ""
                        showPermanentConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.slash.fill")
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Permanently Delete \(engine.permanentDeleteSizeLabel)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(engine.permanentDeleteEligible.count) high-confidence items only")
                                    .font(.system(size: 9))
                                    .opacity(0.8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(engine.isDeleting)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // Recovery / permanence notes
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Trash: recoverable any time from Finder")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if !engine.permanentDeleteEligible.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.7))
                        Text("Permanent delete: irreversible, 90%+ confidence only")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.7))
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: — AI banner (while Haiku is reviewing)

    var aiBanner: some View {
        HStack(spacing: 10) {
            // Animated shimmer dots
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.purple.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(i) * 0.15),
                            value: engine.isAIEnhancing
                        )
                }
            }
            Text("Claude is reviewing your results for better recommendations…")
                .font(.system(size: 11))
                .foregroundColor(.purple)
            Spacer()
            Text("✦ AI-enhanced items will be marked")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }

    func aiSummaryBanner(_ summary: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(.purple)
            Text(summary)
                .font(.system(size: 11))
                .foregroundColor(.primary)
            Spacer()
            Text("✦ Powered by Claude")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.05))
        .overlay(
            Rectangle()
                .fill(Color.purple.opacity(0.2))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: — Empty states

    var analysingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.1)
            Text("Analysing for cleanup opportunities…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !apiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                        .font(.system(size: 11))
                    Text("Claude will review results for deeper insights")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var nothingFoundState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(.teal.opacity(0.4))
            Text("Nothing obvious to clean up")
                .font(.system(size: 14, weight: .semibold))
            Text("This folder looks clean. Try scanning your\nHome folder or Downloads for better results.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Helpers

    private var trashButtonColor: Color {
        switch engine.overallSafety {
        case .safe:    return .teal
        case .caution: return .orange
        case .review:  return .red
        }
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

    private func safetyColor(_ s: SafetyLevel) -> Color {
        switch s {
        case .safe:    return .green
        case .caution: return .orange
        case .review:  return .red
        }
    }
}

// MARK: — Suggestion Row

struct SuggestionRow: View {
    let item:     CleanupItem
    let isStaged: Bool
    let isHovered: Bool
    let onToggle: () -> Void

    var safetyColor: Color {
        switch item.safety {
        case .safe:    return .green
        case .caution: return .orange
        case .review:  return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isStaged ? safetyColor : Color.secondary.opacity(0.08))
                        .frame(width: 22, height: 22)
                    if isStaged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            // Safety badge
            Image(systemName: item.safety.icon)
                .font(.system(size: 13))
                .foregroundColor(safetyColor)
                .frame(width: 18)

            // Name + reason
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.reason)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Right column: category + size + confidence + last accessed
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.category.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(safetyColor.opacity(0.12))
                        .foregroundColor(safetyColor)
                        .clipShape(Capsule())

                    if item.canPermanentlyDelete {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.red.opacity(0.7))
                            .help("Eligible for permanent delete")
                    }
                }

                Text(item.sizeLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)

                // Confidence bar
                VStack(alignment: .trailing, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(confidenceColor)
                                .frame(width: geo.size.width * CGFloat(item.confidence) / 100.0)
                        }
                    }
                    .frame(width: 60, height: 4)

                    Text("\(item.confidence)% · \(item.lastAccessedLabel)")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            isHovered ? Color.primary.opacity(0.03) :
            isStaged  ? safetyColor.opacity(0.04) :
            Color.clear
        )
        .animation(.easeInOut(duration: 0.1), value: isStaged)
    }

    var confidenceColor: Color {
        switch item.confidence {
        case 90...100: return .green
        case 70...89:  return .teal
        case 50...69:  return .orange
        default:       return .red
        }
    }
}

// MARK: — Staged Row (tray)

struct StagedRow: View {
    let item:     CleanupItem
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.safety.icon)
                .font(.system(size: 11))
                .foregroundColor(safetyColor)
                .frame(width: 16)

            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            Text(item.sizeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .onHover { hovered = $0 }
    }

    var safetyColor: Color {
        switch item.safety {
        case .safe:    return .green
        case .caution: return .orange
        case .review:  return .red
        }
    }
}

// MARK: — Category Tab

struct CategoryTab: View {
    let label:      String
    let count:      Int
    let size:       Int64
    let color:      Color
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    Text("\(count)")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? color : Color.secondary.opacity(0.15))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .clipShape(Capsule())
                }
                Text(DiskItem.formatSize(size))
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? color : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.12) : Color.clear)
            .foregroundColor(isSelected ? color : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Safety pill

struct SafetyPill: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count) \(label)")
                .font(.system(size: 9))
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}


// MARK: — Two-step Permanent Delete Confirmation Sheet
// User must type the word "DELETE" exactly before the button enables.
// This is intentional friction — permanent deletion should require
// deliberate thought, not just a button press.

struct PermanentDeleteConfirmSheet: View {
    let eligibleItems: [CleanupItem]
    let totalSize:     String
    @Binding var confirmText: String
    let onConfirm: () -> Void
    let onCancel:  () -> Void

    private let requiredWord = "DELETE"
    private var isConfirmed: Bool { confirmText == requiredWord }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permanent Delete")
                        .font(.system(size: 15, weight: .bold))
                    Text("This cannot be undone — items will not go to Trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Color.red.opacity(0.04))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // What will be deleted
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ITEMS TO BE PERMANENTLY DELETED")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .kerning(0.5)

                        ForEach(eligibleItems.prefix(10)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red.opacity(0.6))
                                Text(item.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(item.sizeLabel)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text("\(item.confidence)% confidence")
                                        .font(.system(size: 9))
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 3)
                            if item.id != eligibleItems.prefix(10).last?.id {
                                Divider().opacity(0.4)
                            }
                        }

                        if eligibleItems.count > 10 {
                            Text("+ \(eligibleItems.count - 10) more items")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    // Why these are eligible
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Why these items are eligible")
                                .font(.system(size: 12, weight: .medium))
                            Text("All \(eligibleItems.count) items scored 90% or higher confidence — they are in known-safe macOS locations (caches, logs, temp files) and have not been accessed recently. macOS or the app will recreate them if needed.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.05))
                    .cornerRadius(8)

                    // Type-to-confirm
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type DELETE to confirm")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Permanently deletes \(totalSize) across \(eligibleItems.count) item(s). This is irreversible.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        TextField("Type DELETE here", text: $confirmText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(isConfirmed ? .red : .primary)
                            .autocorrectionDisabled()
                    }
                }
                .padding(16)
            }

            Divider()

            // Action buttons
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)

                Spacer()

                Button {
                    guard isConfirmed else { return }
                    onConfirm()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.slash.fill")
                        Text("Permanently Delete \(totalSize)")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!isConfirmed)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(14)
        }
        .frame(minWidth: 480, maxWidth: 520)
    }
}
