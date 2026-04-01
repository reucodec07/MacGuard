import SwiftUI

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    
    static func success(_ message: String) -> Toast { Toast(message: message, style: .success) }
    static func error(_ message: String) -> Toast { Toast(message: message, style: .error) }
    static func info(_ message: String) -> Toast { Toast(message: message, style: .info) }
}

struct ToastView: View {
    let message: String
    let style: ToastStyle
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)? = nil
    
    init(message: String, style: ToastStyle, isPresented: Binding<Bool>) {
        self.message = message
        self.style = style
        self._isPresented = isPresented
        self.onDismiss = nil
    }
    
    init(toast: Toast, onDismiss: @escaping () -> Void) {
        self.message = toast.message
        self.style = toast.style
        self._isPresented = .constant(true)
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        if isPresented {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: style.icon)
                        .foregroundColor(style.color)
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minWidth: 200, maxWidth: 350)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                .padding(.bottom, 40)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            isPresented = false
                            onDismiss?()
                        }
                    }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(100)
        }
    }
}

enum ToastStyle {
    case success, error, info
    
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        ToastView(message: "Operation completed successfully", style: .success, isPresented: .constant(true))
    }
    .frame(width: 400, height: 200)
}
