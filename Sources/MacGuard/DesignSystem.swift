import SwiftUI

enum DesignSystem {
    // MARK: - Colors
    enum Colors {
        static let primaryText = Color.primary
        static let secondaryText = Color.secondary
        static let accent = Color.accentColor
        
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let info = Color.blue
        
        static let glassBackground = Color(NSColor.windowBackgroundColor).opacity(0.7)
        static let glassBorder = Color.primary.opacity(0.1)
        static let cardBackground = Color(NSColor.controlBackgroundColor).opacity(0.4)
    }
    
    // MARK: - Spacing & Radii
    enum Metrics {
        static let paddingSmall: CGFloat = 8
        static let paddingMedium: CGFloat = 16
        static let paddingLarge: CGFloat = 24
        
        static let cornerRadiusSmall: CGFloat = 8
        static let cornerRadiusMedium: CGFloat = 12
        static let cornerRadiusLarge: CGFloat = 20
    }
    
    // MARK: - Shadows
    static let cardShadow = Shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
}

struct Shadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - View Modifiers
extension View {
    func glassBackground(cornerRadius: CGFloat = DesignSystem.Metrics.cornerRadiusMedium) -> some View {
        self.background(.regularMaterial)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }
    
    func cardStyle() -> some View {
        self.padding(DesignSystem.Metrics.paddingMedium)
            .background(DesignSystem.Colors.cardBackground)
            .cornerRadius(DesignSystem.Metrics.cornerRadiusMedium)
            .shadow(color: DesignSystem.cardShadow.color, 
                    radius: DesignSystem.cardShadow.radius, 
                    x: DesignSystem.cardShadow.x, 
                    y: DesignSystem.cardShadow.y)
    }
}
