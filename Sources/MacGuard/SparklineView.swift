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
                                let y = h - CGFloat(val) * h
                                i == 0
                                    ? path.addLine(to: CGPoint(x: x, y: y))
                                    : path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: w, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }

                    // ── Line ─────────────────────────────────
                    Path { path in
                        for (i, val) in pts.enumerated() {
                            let x = CGFloat(i) * step
                            let y = h - CGFloat(val) * h
                            i == 0
                                ? path.move(to: CGPoint(x: x, y: y))
                                : path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth,
                                                      lineCap: .round,
                                                      lineJoin: .round))

                    // ── Latest value dot ──────────────────────
                    if let last = pts.last {
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .position(x: w, y: h - CGFloat(last) * h)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))

            } else {
                // Not enough data yet — show placeholder
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        Text("collecting…")
                            .font(.system(size: 7))
                            .foregroundColor(.secondary)
                    )
            }
        }
    }
}
