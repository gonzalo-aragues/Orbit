import AppKit
import SwiftUI

struct Annotation: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case pen, highlighter, arrow, rectangle, ellipse, text }

    let id = UUID()
    var kind: Kind
    var color: RGB
    /// Stroke width in image pixels.
    var width: CGFloat
    /// Image-pixel coordinates, top-left origin.
    var points: [CGPoint]
    var text = ""

    /// Draws in a top-left-origin context whose units are image pixels times `scale`.
    func draw(in ctx: CGContext, scale: CGFloat) {
        let pts = points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let first = pts.first else { return }
        let w = width * scale
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cg)
        ctx.setFillColor(color.cg)
        switch kind {
        case .pen, .highlighter:
            if kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setAlpha(0.45)
                ctx.setLineCap(.square)
            }
            ctx.setLineWidth(kind == .highlighter ? w * 3.5 : w)
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: first) }
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .arrow:
            guard let last = pts.last, pts.count > 1 else { break }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(w * 4.5, 12 * scale)
            let shaftEnd = CGPoint(x: last.x - cos(angle) * head * 0.6, y: last.y - sin(angle) * head * 0.6)
            ctx.setLineWidth(w)
            ctx.move(to: first)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.move(to: last)
            ctx.addLine(to: CGPoint(x: last.x - cos(angle - 0.45) * head, y: last.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: last.x - cos(angle + 0.45) * head, y: last.y - sin(angle + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle, .ellipse:
            guard let last = pts.last else { break }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.setLineWidth(w)
            if kind == .rectangle {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(w * 1.5, r.width / 2), cornerHeight: min(w * 1.5, r.height / 2), transform: nil))
            } else {
                ctx.addEllipse(in: r)
            }
            ctx.strokePath()
        case .text:
            let font = NSFont.systemFont(ofSize: max(w * 6, 10 * scale), weight: .bold)
            let string = NSAttributedString(string: text.isEmpty ? "Text" : text,
                                            attributes: [.font: font, .foregroundColor: NSColor(cgColor: color.cg) ?? .red])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            string.draw(at: CGPoint(x: first.x, y: first.y - font.pointSize * 0.6))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }
}

struct AnnotateEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void

    private let preview: CGImage
    private let imageSize: CGSize

    @State private var annotations: [Annotation] = []
    @State private var draft: Annotation?
    @State private var tool: Annotation.Kind = .arrow
    @State private var color = RGB(0xF2551F)
    @State private var strokeWidth = 4.0
    @State private var editingText: UUID?

    private static let palette: [RGB] = [RGB(0xF2551F), RGB(0xFF3B30), RGB(0xFFCC00), RGB(0x34C759), RGB(0x007AFF), RGB(0x111111), RGB(0xFFFFFF)]

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.close = close
        preview = ImageIOUtil.downscale(image, maxDimension: 1600) ?? image
        imageSize = image.size
    }

    var body: some View {
        VStack(spacing: 16) {
            toolbar

            PreviewWell {
                GeometryReader { geo in
                    let fit = fitRect(imageSize, in: geo.size)
                    let s = fit.width / max(imageSize.width, 1)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                        Canvas { context, _ in
                            context.withCGContext { cg in
                                for a in annotations { a.draw(in: cg, scale: s) }
                                draft?.draw(in: cg, scale: s)
                            }
                        }
                        .frame(width: fit.width, height: fit.height)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .gesture(drawGesture(scale: s))
                    .offset(x: fit.minX, y: fit.minY)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
            }

            if let id = editingText, let index = annotations.firstIndex(where: { $0.id == id }) {
                ControlRow(label: "Text") {
                    TextField("Type your note", text: $annotations[index].text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.7)))
                        .onSubmit { editingText = nil }
                }
            }

            ValueSlider(label: "Size", value: $strokeWidth, range: 1...20, unit: "pt")

            HStack {
                Button("Undo") { if !annotations.isEmpty { annotations.removeLast(); editingText = nil } }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut("z")
                    .disabled(annotations.isEmpty)
                Button("Clear") { annotations.removeAll(); editingText = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(annotations.isEmpty)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Annotation.Kind.allCases, id: \.self) { kind in
                    let selected = tool == kind
                    Button { tool = kind } label: {
                        Image(systemName: symbol(kind))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? Color.white : Theme.ink.opacity(0.75))
                            .frame(width: 34, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(kind.rawValue.capitalized)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.4)))

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(Self.palette, id: \.self) { c in
                    Button { color = c; recolorEditingText(c) } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3.5).opacity(color == c ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func symbol(_ kind: Annotation.Kind) -> String {
        switch kind {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }

    private func recolorEditingText(_ c: RGB) {
        guard let id = editingText, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].color = c
    }

    private func drawGesture(scale s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = CGPoint(x: value.location.x / s, y: value.location.y / s)
                if draft == nil {
                    let start = CGPoint(x: value.startLocation.x / s, y: value.startLocation.y / s)
                    draft = Annotation(kind: tool, color: color, width: strokeWidth / s, points: [start])
                    if tool != .text { editingText = nil }
                }
                switch tool {
                case .pen, .highlighter: draft?.points.append(p)
                case .text: draft?.points = [p]
                default: draft?.points = [draft!.points[0], p]
                }
            }
            .onEnded { _ in
                guard var a = draft else { return }
                draft = nil
                if a.kind == .text {
                    a.text = ""
                    annotations.append(a)
                    editingText = a.id
                    return
                }
                if a.kind != .pen && a.kind != .highlighter, a.points.count < 2 { return }
                annotations.append(a)
            }
    }

    private func save() {
        let w = image.width, h = image.height
        guard let ctx = ImageIOUtil.context(width: w, height: h) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for a in annotations { a.draw(in: ctx, scale: 1) }
        guard let out = ctx.makeImage() else { return }
        Editors.save(out, from: url, suffix: "Annotated", close: close)
    }
}
