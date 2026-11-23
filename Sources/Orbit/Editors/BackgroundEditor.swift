import AppKit
import SwiftUI

struct RGB: Hashable {
    let r, g, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    var color: Color { Color(red: r, green: g, blue: b) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A soft "mesh" gradient: a diagonal blend plus a couple of glowing blobs.
struct GradientPreset: Hashable {
    let stops: [RGB]
    let blobs: [(RGB, CGPoint)]

    static func == (a: GradientPreset, b: GradientPreset) -> Bool { a.stops == b.stops }
    func hash(into h: inout Hasher) { h.combine(stops) }

    static let all: [GradientPreset] = [
        GradientPreset(stops: [RGB(0xFF5A1F), RGB(0xFF2E7E), RGB(0x7B4DFF)], blobs: [(RGB(0xFFC233), CGPoint(x: 0.85, y: 0.1))]),
        GradientPreset(stops: [RGB(0xFDE2E4), RGB(0xE2ECE9), RGB(0xCDDAFD)], blobs: [(RGB(0xFFF1E6), CGPoint(x: 0.2, y: 0.2))]),
        GradientPreset(stops: [RGB(0xFF6B6B), RGB(0xFFD93D), RGB(0x6BCB77), RGB(0x4D96FF)], blobs: []),
        GradientPreset(stops: [RGB(0xFFDDE1), RGB(0xEE9CA7)], blobs: [(RGB(0xFFFFFF), CGPoint(x: 0.3, y: 0.25))]),
        GradientPreset(stops: [RGB(0xE0C3FC), RGB(0x8EC5FC)], blobs: [(RGB(0xFBC2EB), CGPoint(x: 0.8, y: 0.8))]),
        GradientPreset(stops: [RGB(0x0F2027), RGB(0x203A43), RGB(0x2C5364)], blobs: [(RGB(0xFF5F6D), CGPoint(x: 0.2, y: 0.85)), (RGB(0x24C6DC), CGPoint(x: 0.85, y: 0.15))]),
        GradientPreset(stops: [RGB(0x2193B0), RGB(0x6DD5ED)], blobs: [(RGB(0xB2FEFA), CGPoint(x: 0.2, y: 0.8))]),
        GradientPreset(stops: [RGB(0xD4FC79), RGB(0x96E6A1)], blobs: [(RGB(0xFFF9C4), CGPoint(x: 0.75, y: 0.2))]),
    ]

    var swatch: some View {
        ZStack {
            LinearGradient(colors: stops.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                RadialGradient(colors: [blob.0.color.opacity(0.85), blob.0.color.opacity(0)],
                               center: UnitPoint(x: blob.1.x, y: blob.1.y), startRadius: 0, endRadius: 22)
            }
        }
    }

    func draw(in ctx: CGContext, rect: CGRect) {
        let colors = stops.map(\.cg) as CFArray
        if let g = CGGradient(colorsSpace: ImageIOUtil.sRGB, colors: colors, locations: nil) {
            // Bitmap contexts are y-up, so "top-left" is (minX, maxY).
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let radius = max(rect.width, rect.height) * 0.7
        for (color, unit) in blobs {
            let c = CGPoint(x: rect.minX + unit.x * rect.width, y: rect.maxY - unit.y * rect.height)
            let colors = [color.cg.copy(alpha: 0.85)!, color.cg.copy(alpha: 0)!] as CFArray
            if let g = CGGradient(colorsSpace: ImageIOUtil.sRGB, colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
            }
        }
    }
}

enum Backdrop: Hashable {
    case gradient(GradientPreset)
    case solid(RGB)
    case image(URL)

    static let solids: [RGB] = [
        RGB(0xFFFFFF), RGB(0xF5C542), RGB(0x8BC34A), RGB(0x2E9E6B), RGB(0x1D8F84),
        RGB(0x4FC3D9), RGB(0x3B5BDB), RGB(0x2B2D42), RGB(0x7C4DFF),
    ]
}

struct BackgroundSettings: Hashable {
    var backdrop: Backdrop = .gradient(GradientPreset.all[0])
    var padding: Double = 160
    var corners: Double = 24
    var shadow: Double = 24
    var ratio: Ratio = .auto

    enum Ratio: Hashable, CaseIterable {
        case auto, square, wide, portrait
        var label: String {
            switch self {
            case .auto: "Auto"
            case .square: "1:1"
            case .wide: "16:9"
            case .portrait: "4:5"
            }
        }
        var value: CGFloat? {
            switch self {
            case .auto: nil
            case .square: 1
            case .wide: 16.0 / 9
            case .portrait: 4.0 / 5
            }
        }
    }
}

enum BackgroundRenderer {
    /// Renders the framed image. For previews pass a downscaled `image` and the matching `scale`,
    /// which shrinks padding, corners and shadow by the same amount.
    static func render(_ image: CGImage, _ s: BackgroundSettings, scale: CGFloat = 1, backdropImage: CGImage?) -> CGImage? {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let pad = CGFloat(s.padding) * scale
        var cw = iw + pad * 2, ch = ih + pad * 2
        if let r = s.ratio.value {
            if cw / ch < r { cw = ch * r } else { ch = cw / r }
        }
        let W = max(1, Int(cw.rounded())), H = max(1, Int(ch.rounded()))
        guard let ctx = ImageIOUtil.context(width: W, height: H) else { return nil }
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.interpolationQuality = .high

        switch s.backdrop {
        case .gradient(let g): g.draw(in: ctx, rect: full)
        case .solid(let c):
            ctx.setFillColor(c.cg)
            ctx.fill(full)
        case .image:
            if let bg = backdropImage {
                let k = max(full.width / CGFloat(bg.width), full.height / CGFloat(bg.height))
                let w = CGFloat(bg.width) * k, h = CGFloat(bg.height) * k
                ctx.draw(bg, in: CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h))
            } else {
                ctx.setFillColor(.white)
                ctx.fill(full)
            }
        }

        let frame = CGRect(x: (CGFloat(W) - iw) / 2, y: (CGFloat(H) - ih) / 2, width: iw, height: ih)
        let radius = min(CGFloat(s.corners) * scale, min(iw, ih) / 2)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if s.shadow > 0 {
            ctx.saveGState()
            let blur = CGFloat(s.shadow) * scale * 1.6
            ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(s.shadow) * scale * 0.45), blur: blur,
                          color: CGColor(gray: 0, alpha: 0.38))
            ctx.addPath(path)
            ctx.setFillColor(.white)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: frame)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

struct BackgroundEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void

    private let previewSource: CGImage
    private let previewScale: CGFloat

    @State private var settings = BackgroundSettings()
    @State private var rendered: CGImage?
    @State private var backdropImage: CGImage?
    @State private var customColor = Color(red: 0.25, green: 0.45, blue: 0.95)

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.close = close
        let small = ImageIOUtil.downscale(image, maxDimension: 800) ?? image
        previewSource = small
        previewScale = CGFloat(small.width) / CGFloat(max(image.width, 1))
    }

    var body: some View {
        VStack(spacing: 18) {
            PreviewWell {
                if let rendered {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                ControlRow(label: "Background") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            ForEach(GradientPreset.all, id: \.self) { preset in
                                swatchButton(.gradient(preset)) { preset.swatch }
                            }
                            Button(action: pickImage) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink.opacity(0.7))
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.55)))
                                    .overlay(selectionRing(isImage))
                            }
                            .buttonStyle(.plain)
                            .help("Use an image as the background")
                        }
                        HStack(spacing: 7) {
                            ForEach(Backdrop.solids, id: \.self) { c in
                                swatchButton(.solid(c)) { c.color }
                            }
                            ColorPicker("", selection: $customColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 30, height: 30)
                                .onChange(of: customColor) { useCustomColor() }
                        }
                    }
                }
                ValueSlider(label: "Padding", value: $settings.padding, range: 0...1000)
                ValueSlider(label: "Corners", value: $settings.corners, range: 0...400)
                ValueSlider(label: "Shadow", value: $settings.shadow, range: 0...120)
                ControlRow(label: "Ratio") {
                    Spacer(minLength: 0)
                    PillPicker(options: BackgroundSettings.Ratio.allCases.map { ($0, $0.label) }, selection: $settings.ratio)
                }
            }

            HStack {
                Button("Reset") { withAnimation { settings = BackgroundSettings() } }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Save with Background") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .task(id: settings) { rerender() }
        .task(id: backdropImage == nil) { rerender() }
    }

    private var isImage: Bool { if case .image = settings.backdrop { true } else { false } }

    private func selectionRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Theme.accent : .white.opacity(0.6), lineWidth: selected ? 2.5 : 1)
            .padding(-2.5)
            .opacity(selected ? 1 : 0.7)
    }

    private func swatchButton<V: View>(_ backdrop: Backdrop, @ViewBuilder fill: () -> V) -> some View {
        let selected = settings.backdrop == backdrop
        return Button { settings.backdrop = backdrop } label: {
            fill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                )
                .overlay(selected ? selectionRing(true) : nil)
        }
        .buttonStyle(.plain)
    }

    private func useCustomColor() {
        let ns = NSColor(customColor).usingColorSpace(.sRGB) ?? .white
        settings.backdrop = .solid(RGB(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent))
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let picked = panel.url, let bg = try? ImageIOUtil.load(picked) else { return }
        backdropImage = ImageIOUtil.downscale(bg, maxDimension: 4000)
        settings.backdrop = .image(picked)
    }

    private func rerender() {
        rendered = BackgroundRenderer.render(previewSource, settings, scale: previewScale, backdropImage: backdropImage)
    }

    private func save() {
        guard let out = BackgroundRenderer.render(image, settings, scale: 1, backdropImage: backdropImage) else { return }
        Editors.save(out, from: url, suffix: "With Background", ext: "png", close: close)
    }
}
