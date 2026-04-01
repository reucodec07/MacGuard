import SwiftUI

struct DiskItemInspector: View {
    let item: DiskItem
    let onDrillDown: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(iconColor.opacity(0.1))
                            .frame(width: 56, height: 56)
                        Image(systemName: item.isPending ? "hourglass" : item.icon)
                            .font(.system(size: 24))
                            .foregroundColor(iconColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(2)
                        Text(item.url.path)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
                
                Divider()
                
                // Stats Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    DiskStatCard(label: "Size", value: item.sizeLabel, icon: "scalemass", color: Color.blue)
                    DiskStatCard(label: "Type", value: typeLabel, icon: "tag", color: Color.purple)
                    if item.itemCount >= 0 {
                        DiskStatCard(label: "Contents", value: "\(item.itemCount) items", icon: "folder", color: Color.teal)
                    }
                    DiskStatCard(label: "Kind", value: item.isPackage ? "App/Package" : (item.isDir ? "Folder" : "File"), icon: "info.circle", color: Color.orange)
                }
                
                // Actions
                VStack(spacing: 12) {
                    Button(action: {
                        NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                    }) {
                        Label("Reveal in Finder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    if item.isDir && !item.isPackage && !item.isPending {
                        Button(action: onDrillDown) {
                            Label("Drill Down", systemImage: "arrow.down.right.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.teal)
                    }
                }
                
                Spacer(minLength: 40)
            }
            .padding(24)
        }
    }
    
    private var typeLabel: String {
        if item.isPackage { return "Package" }
        if item.isDir { return "Directory" }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) File"
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

private struct DiskStatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(12)
    }
}
