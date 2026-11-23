import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum RedactStyle: Hashable, CaseIterable {
    case black, pixelate, blur
    var label: String {
        switch self {
        case .black: "Black Bar"
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        }
    }
}

enum Redactor {
    private static let context = CIContext(options: [.workingColorSpace: ImageIOUtil.sRGB])

    /// `rects` are in the image's own pixel space, top-left origin.
    static func apply(_ image: CGImage, rects: [CGRect], style: RedactStyle) -> CGImage? {
        guard !rects.isEmpty else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let flipped = rects.map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }
        if style == .black {
            guard let ctx = ImageIOUtil.context(width: image.width, height: image.height) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            for r in flipped {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil))
            }
            ctx.fillPath()
            return ctx.makeImage()
        }
        let input = CIImage(cgImage: image)
        let effect: CIImage
        if style == .pixelate {
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(max(8, min(w, h) / 45))
            f.center = .zero
            effect = f.outputImage ?? input
        } else {
            let f = CIFilter.gaussianBlur()
            f.inputImage = input.clampedToExtent()
            f.radius = Float(max(10, min(w, h) / 40))
            effect = f.outputImage ?? input
        }
        var output = input
        for r in flipped {
            output = effect.cropped(to: r).composited(over: output)
        }
        return context.createCGImage(output, from: input.extent)
    }
}

struct RedactEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void

    private let preview: CGImage
    private let previewScale: CGFloat
    private let imageSize: CGSize

    @State private var rects: [CGRect] = []
    @State private var draft: CGRect?
    @State private var style: RedactStyle = .black
    @State private var rendered: CGImage?
    @State private var detecting = false

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.close = close
        let small = ImageIOUtil.downscale(image, maxDimension: 1400) ?? image
        preview = small
        previewScale = CGFloat(small.width) / CGFloat(max(image.width, 1))
        imageSize = image.size
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                PillPicker(options: RedactStyle.allCases.map { ($0, $0.label) }, selection: $style)
                Spacer()
                Button {
                    detectText()
                } label: {
                    Label(detecting ? "Finding…" : "Redact All Text", systemImage: "text.viewfinder")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(detecting)
            }

            PreviewWell {
                GeometryReader { geo in
                    let fit = fitRect(imageSize, in: geo.size)
                    let s = fit.width / max(imageSize.width, 1)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: rendered ?? preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                        if let d = draft {
                            Rectangle()
                                .fill(Theme.accent.opacity(0.18))
                                .overlay(Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                                .frame(width: d.width * s, height: d.height * s)
                                .offset(x: d.minX * s, y: d.minY * s)
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                let a = CGPoint(x: v.startLocation.x / s, y: v.startLocation.y / s)
                                let b = CGPoint(x: v.location.x / s, y: v.location.y / s)
                                draft = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                                    .intersection(CGRect(origin: .zero, size: imageSize))
                            }
                            .onEnded { _ in
                                if let d = draft, d.width > 3, d.height > 3 { rects.append(d) }
                                draft = nil
                            }
                    )
                    .offset(x: fit.minX, y: fit.minY)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
            }

            Text("Drag over anything you want hidden.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.55))

            HStack {
                Button("Undo") { if !rects.isEmpty { rects.removeLast() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut("z")
                    .disabled(rects.isEmpty)
                Button("Clear") { rects.removeAll() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(rects.isEmpty)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(rects.isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .task(id: RenderKey(rects: rects, style: style)) {
            let scaled = rects.map { CGRect(x: $0.minX * previewScale, y: $0.minY * previewScale,
                                            width: $0.width * previewScale, height: $0.height * previewScale) }
            rendered = Redactor.apply(preview, rects: scaled, style: style)
        }
    }

    private struct RenderKey: Hashable {
        let rects: [CGRect]
        let style: RedactStyle
        static func == (a: RenderKey, b: RenderKey) -> Bool { a.rects == b.rects && a.style == b.style }
        func hash(into h: inout Hasher) {
            h.combine(style)
            for r in rects { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
        }
    }

    private func detectText() {
        detecting = true
        let source = image
        let size = imageSize
        Task {
            let lines = (try? await offMain { try ImageIOUtil.recognizeText(source) }) ?? []
            let found = lines.map { line -> CGRect in
                let b = line.box
                let pad = max(2, b.height * size.height * 0.15)
                return CGRect(x: b.minX * size.width - pad, y: (1 - b.maxY) * size.height - pad,
                              width: b.width * size.width + pad * 2, height: b.height * size.height + pad * 2)
                    .intersection(CGRect(origin: .zero, size: size))
            }
            rects += found
            detecting = false
            if found.isEmpty { HUD.shared.flash(title: "No text found", detail: "Drag over areas to redact them by hand.") }
        }
    }

    private func save() {
        guard let out = Redactor.apply(image, rects: rects, style: style) else { return }
        Editors.save(out, from: url, suffix: "Redacted", close: close)
    }
}
