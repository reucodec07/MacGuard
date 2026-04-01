import SwiftUI

struct SparklineView: View {
    let data:      [Double]
    var color:     Color    = .blue
    var lineWidth: CGFloat  = 1.5
    var showFill:  Bool     = true

    private var normalised: [Double] {
        guard data.count >= 2 else { return data }
        let lo = data.min() ?? 0
        let hi = max(data.max() ?? 1, lo + 1)
        return data.map { ($0 - lo) / (hi - lo) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = normalised

            if pts.count >= 2 {
                let step = w / CGFloat(pts.count - 1)

                ZStack {
                    // ── Fill area ────────────────────────────
                    if showFill {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: h))
                            for (i, val) in pts.enumerated() {
                                let x = CGFloat(i) * step
                                let y = h - (CGFloat(val) * (h - 4) + 2)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: w, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.3), color.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }

                    // ── Line ─────────────────────────────────
                    Path { path in
                        for (i, val) in pts.enumerated() {
                            let x = CGFloat(i) * step
                            let y = h - (CGFloat(val) * (h - 4) + 2)
                            i == 0
                                ? path.move(to: CGPoint(x: x, y: y))
                                : path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth,
                                                      lineCap: .round,
                                                      lineJoin: .round))
                    .shadow(color: color.opacity(0.3), radius: 2, x: 0, y: 1)

                    // ── Latest value dot ──────────────────────
                    if let last = pts.last {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                            .shadow(color: .black.opacity(0.2), radius: 1)
                            .overlay(Circle().stroke(color, lineWidth: 1.5))
                            .position(x: w, y: h - (CGFloat(last) * (h - 4) + 2))
                    }
                }
            } else {
                // Not enough data yet — show premium placeholder
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).scaleEffect(0.5)
                            Text("Collecting...")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
    }
}
