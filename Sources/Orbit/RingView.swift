import SwiftUI

enum RingGeometry {
    static let size: CGFloat = 400
    static let disk: CGFloat = 176
    static let segmentOuter: CGFloat = 164
    static let segmentInner: CGFloat = 74
    static let hole: CGFloat = 66
    static let gap: CGFloat = 7
    static let corner: CGFloat = 16
    static let labelRadius: CGFloat = (segmentOuter + segmentInner) / 2 + 2

    /// Angle (radians, y-down, clockwise from +x) of the centre of segment `index`. Segment 0 sits at the top.
    static func centerAngle(_ index: Int, of count: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(count, 1))
    }

    /// Hit-tests a point relative to the ring centre (y-down).
    static func hover(dx: CGFloat, dy: CGFloat, count: Int) -> RingHover {
        let r = hypot(dx, dy)
        if r <= segmentInner - 4 { return .hub }
        if r > disk || count == 0 { return .none }
        let step = 2 * Double.pi / Double(count)
        var angle = atan2(Double(dy), Double(dx)) + .pi / 2   // 0 at top, clockwise
        if angle < 0 { angle += 2 * .pi }
        let index = Int((angle / step).rounded()) % count
        return .item(index)
    }
}

/// An annular sector with parallel-sided gaps and rounded corners.
struct SectorShape: Shape {
    let index: Int
    let count: Int
    var inner: CGFloat = RingGeometry.segmentInner
    var outer: CGFloat = RingGeometry.segmentOuter
    var gap: CGFloat = RingGeometry.gap
    var corner: CGFloat = RingGeometry.corner

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        if count <= 1 {
            var p = Path()
            p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            return p
        }
        let step = 2 * Double.pi / Double(count)
        let mid = RingGeometry.centerAngle(index, of: count)
        let start = mid - step / 2, end = mid + step / 2
        let d = Double(gap / 2 + corner)
        let ro = Double(outer - corner), ri = Double(inner + corner)
        let path = CGMutablePath()
        path.addArc(center: c, radius: ro, startAngle: start + asin(d / ro), endAngle: end - asin(d / ro), clockwise: false)
        path.addArc(center: c, radius: ri, startAngle: end - asin(d / ri), endAngle: start + asin(d / ri), clockwise: true)
        path.closeSubpath()
        let rounded = path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return Path(path.union(rounded))
    }
}

struct RingView: View {
    let model: RingModel

    var body: some View {
        let g = RingGeometry.self
        ZStack {
            // Base disc of glass
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .glassEffect(.regular, in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15), .white.opacity(0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.2)
                )
                .frame(width: g.disk * 2, height: g.disk * 2)
                .shadow(color: .black.opacity(0.16), radius: 30, y: 14)

            ZStack {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    SegmentView(item: item, index: index, count: model.items.count,
                                hovered: model.hover == .item(index))
                }
            }
            .id(model.page)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.82).combined(with: .opacity),
                removal: .scale(scale: 1.12).combined(with: .opacity)))

            // Hole rim
            Circle()
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                .background(Circle().fill(.white.opacity(0.06)))
                .frame(width: g.hole * 2, height: g.hole * 2)

            HubView(model: model)
        }
        .frame(width: g.size, height: g.size)
        .scaleEffect(model.shown ? 1 : (model.committing ? 1.08 : 0.55))
        .opacity(model.shown ? 1 : 0)
        .blur(radius: model.shown ? 0 : 6)
        .environment(\.colorScheme, .light)
    }
}

private struct SegmentView: View {
    let item: RingItem
    let index: Int
    let count: Int
    let hovered: Bool

    var body: some View {
        let shape = SectorShape(index: index, count: count)
        let angle = RingGeometry.centerAngle(index, of: count)
        let r = count <= 1 ? 0 : RingGeometry.labelRadius
        let pop: CGFloat = hovered && count > 1 ? 4 : 0
        ZStack {
            shape
                .fill(hovered
                      ? AnyShapeStyle(LinearGradient(colors: [Theme.accentLight, Theme.accentDeep], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.66), .white.opacity(0.48)], startPoint: .top, endPoint: .bottom)))
            shape
                .stroke(LinearGradient(colors: [.white.opacity(hovered ? 0.55 : 0.95), .white.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
            label
                .offset(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r + (count <= 1 ? -RingGeometry.labelRadius : 0))
        }
        .frame(width: RingGeometry.size, height: RingGeometry.size)
        .shadow(color: hovered ? Theme.accent.opacity(0.55) : .black.opacity(0.07),
                radius: hovered ? 16 : 3, y: hovered ? 5 : 1)
        .offset(x: CGFloat(cos(angle)) * pop, y: CGFloat(sin(angle)) * pop)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: hovered)
    }

    @ViewBuilder private var label: some View {
        let color = hovered ? Color.white : Theme.ink
        if let symbol = item.symbol {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(item.title).font(.system(size: 11, weight: .bold)).tracking(0.4)
            }
            .foregroundStyle(color)
        } else {
            Text(item.title)
                .font(.system(size: 15, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(color)
        }
    }
}

private struct HubView: View {
    let model: RingModel

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: model.dwell)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: RingGeometry.hole * 2 - 6, height: RingGeometry.hole * 2 - 6)
                .opacity(model.dwell > 0 ? 1 : 0)

            VStack(spacing: 4) {
                Text(model.hubText)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.interpolate)
                if model.canToggle {
                    HStack(spacing: 4) {
                        Circle().frame(width: 4, height: 4).opacity(model.page == .convert ? 0.8 : 0.25)
                        Circle().frame(width: 4, height: 4).opacity(model.page == .tools ? 0.8 : 0.25)
                    }
                    .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 112, height: 46)
            .background(Capsule().fill(.white.opacity(0.55)))
            .glassEffect(.regular.interactive(), in: Capsule())
            .animation(.easeOut(duration: 0.15), value: model.hubText)
        }
    }
}
