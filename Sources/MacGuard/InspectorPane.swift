import SwiftUI

struct InspectorPane<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    let content: () -> Content
    
    var body: some View {
        if isPresented {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .kerning(0.5)
                    Spacer()
                    Button {
                        withAnimation { isPresented = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Divider()
                
                ScrollView {
                    content()
                        .padding(16)
                }
            }
            .frame(width: 280)
            .background(.regularMaterial)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1),
                alignment: .leading
            )
            .transition(.move(edge: .trailing))
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        Color.white
        InspectorPane(title: "Process Details", isPresented: .constant(true)) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Path: /bin/ls", systemImage: "folder")
                Label("User: root", systemImage: "person")
                Label("Threads: 4", systemImage: "cpu")
            }
            .font(.system(size: 12))
        }
    }
    .frame(width: 600, height: 400)
}
