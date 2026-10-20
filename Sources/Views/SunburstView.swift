import SwiftUI

/// One drawable ring segment. Angles are in radians, clockwise from 12 o'clock.
struct SunburstArc: Identifiable {
    let id: String
    /// The represented item, or nil for a merged "Smaller items" arc.
    let node: FileNode?
    let label: String
    let size: Int64
    let parentSize: Int64
    let depth: Int
    let start: Double
    let end: Double
    let color: Color
}

/// Computes sunburst geometry recursively from a center node.
enum SunburstLayout {
    static let minAngle = 0.004
    static let mergeFraction = 0.01

    static func arcs(center: FileNode, maxDepth: Int) -> [SunburstArc] {
        var out: [SunburstArc] = []
        guard center.size > 0 else { return out }
        func layout(_ parent: FileNode, depth: Int, start: Double, span: Double, hue: Double?) {
            guard depth <= maxDepth, parent.size > 0 else { return }
            var angle = start
            var small: Int64 = 0
            for (index, child) in parent.children.enumerated() {
                let fraction = Double(child.size) / Double(parent.size)
                let sweep = span * fraction
                if child.isAggregate || fraction < mergeFraction || sweep < minAngle {
                    small += child.size
                    continue
                }
                let branchHue = hue ?? (Double(index) * 0.618034).truncatingRemainder(dividingBy: 1)
                out.append(SunburstArc(id: child.id, node: child, label: child.name, size: child.size,
                                       parentSize: parent.size, depth: depth, start: angle, end: angle + sweep,
                                       color: Color(hue: branchHue, saturation: 0.62,
                                                    brightness: max(0.45, 0.95 - Double(depth - 1) * 0.09))))
                if child.isDirectory { layout(child, depth: depth + 1, start: angle, span: sweep, hue: branchHue) }
                angle += sweep
            }
            let smallSweep = span * Double(small) / Double(parent.size)
            if small > 0, smallSweep >= minAngle {
                out.append(SunburstArc(id: parent.id + "/#smaller", node: nil, label: "Smaller items", size: small,
                                       parentSize: parent.size, depth: depth, start: angle, end: angle + smallSweep,
                                       color: Color(white: max(0.45, 0.72 - Double(depth - 1) * 0.05))))
            }
        }
        layout(center, depth: 1, start: 0, span: 2 * .pi, hue: nil)
        return out
    }
}

/// Interactive sunburst chart drawn in a Canvas with polar hit-testing.
struct SunburstView: View {
    let center: FileNode
    let maxDepth: Int
    let selectedID: String?
    @Binding var hovered: SunburstArc?
    let onTapArc: (SunburstArc) -> Void
    let onTapCenter: () -> Void

    private var arcs: [SunburstArc] { SunburstLayout.arcs(center: center, maxDepth: maxDepth) }

    var body: some View {
        let arcs = self.arcs
        GeometryReader { geo in
            let g = Geometry(size: geo.size, maxDepth: maxDepth)
            Canvas { ctx, _ in
                let hole = Path(ellipseIn: CGRect(x: g.mid.x - g.inner, y: g.mid.y - g.inner,
                                                  width: g.inner * 2, height: g.inner * 2))
                ctx.fill(hole, with: .color(.secondary.opacity(0.2)))
                for arc in arcs {
                    let path = g.path(for: arc)
                    let isHot = arc.id == hovered?.id
                    ctx.fill(path, with: .color(isHot ? arc.color.opacity(0.75) : arc.color))
                    ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
                    if arc.id == selectedID { ctx.stroke(path, with: .color(.accentColor), lineWidth: 2.5) }
                }
                let title = Text(center.name).font(.headline)
                let size = Text(Bytes.format(center.size)).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                ctx.draw(title, at: CGPoint(x: g.mid.x, y: g.mid.y - 10), anchor: .center)
                ctx.draw(size, at: CGPoint(x: g.mid.x, y: g.mid.y + 12), anchor: .center)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = g.hit(point, arcs: arcs)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if g.isInCenter(value.location) { onTapCenter() }
                else if let arc = g.hit(value.location, arcs: arcs) { onTapArc(arc) }
            })
        }
    }

    /// Ring radii for a given canvas size, plus polar conversions.
    struct Geometry {
        let mid: CGPoint
        let inner: CGFloat
        let ring: CGFloat

        init(size: CGSize, maxDepth: Int) {
            let outer = max(40, min(size.width, size.height) / 2 - 12)
            mid = CGPoint(x: size.width / 2, y: size.height / 2)
            inner = outer * 0.24
            ring = (outer - inner) / CGFloat(max(1, maxDepth))
        }

        func path(for arc: SunburstArc) -> Path {
            let r0 = inner + ring * CGFloat(arc.depth - 1), r1 = r0 + ring
            let a0 = Angle(radians: arc.start - .pi / 2), a1 = Angle(radians: arc.end - .pi / 2)
            var p = Path()
            p.addArc(center: mid, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
            p.addArc(center: mid, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
            p.closeSubpath()
            return p
        }

        func isInCenter(_ point: CGPoint) -> Bool {
            hypot(point.x - mid.x, point.y - mid.y) < inner
        }

        func hit(_ point: CGPoint, arcs: [SunburstArc]) -> SunburstArc? {
            let dx = Double(point.x - mid.x), dy = Double(point.y - mid.y)
            let radius = hypot(dx, dy)
            guard radius >= Double(inner) else { return nil }
            let depth = Int((radius - Double(inner)) / Double(ring)) + 1
            var angle = atan2(dy, dx) + .pi / 2
            if angle < 0 { angle += 2 * .pi }
            return arcs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
        }
    }
}
