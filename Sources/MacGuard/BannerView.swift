import SwiftUI

struct BannerView: View {
    let title: String
    let subtitle: String?
    let style: BannerStyle
    let actionLabel: String?
    let action: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 18))
                .foregroundColor(style.color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if let actionLabel = actionLabel, let action = action {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(style.color.opacity(0.08))
        .cornerRadius(DesignSystem.Metrics.cornerRadiusSmall)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Metrics.cornerRadiusSmall)
                .stroke(style.color.opacity(0.15), lineWidth: 1)
        )
    }
}

enum BannerStyle {
    case info, warning, critical
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        BannerView(
            title: "Full Disk Access Required",
            subtitle: "Enable MacGuard in System Settings for deeper analysis.",
            style: .warning,
            actionLabel: "Open Settings",
            action: {}
        )
        
        BannerView(
            title: "System Optimized",
            subtitle: "All background tasks are running smoothly.",
            style: .info,
            actionLabel: nil,
            action: nil
        )
    }
    .padding()
    .frame(width: 500)
}
