import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct Adjustments: Hashable {
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var sharpness = 0.0
    var vignette = 0.0
    var quarterTurns = 0
    var flipped = false

    func apply(to input: CIImage) -> CIImage {
        var img = input
        if flipped { img = img.oriented(.upMirrored) }
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 1 { img = img.oriented(.right) }
        if turns == 2 { img = img.oriented(.down) }
        if turns == 3 { img = img.oriented(.left) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let extent = img.extent

        if exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(exposure)
            img = f.outputImage ?? img
        }
        if contrast != 0 || saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.contrast = Float(1 + contrast * 0.5)
            f.saturation = Float(1 + saturation)
            img = f.outputImage ?? img
        }
        if warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - warmth * 2500, y: 0)
            img = f.outputImage ?? img
        }
        if sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(sharpness)
            f.radius = 2
            img = f.outputImage ?? img
        }
        if vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = img
            f.intensity = Float(vignette)
            f.radius = 1.5
            img = f.outputImage ?? img
        }
        return img.cropped(to: extent)
    }
}

struct AdjustEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void

    private let previewSource: CIImage
    private static let context = CIContext(options: [.workingColorSpace: ImageIOUtil.sRGB])

    @State private var adjustments = Adjustments()
    @State private var rendered: CGImage?

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.close = close
        previewSource = CIImage(cgImage: ImageIOUtil.downscale(image, maxDimension: 1100) ?? image)
    }

    var body: some View {
        VStack(spacing: 18) {
            PreviewWell {
                if let rendered {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
            }

            VStack(spacing: 12) {
                ValueSlider(label: "Exposure", value: $adjustments.exposure, range: -2...2, unit: "EV", format: signed1)
                ValueSlider(label: "Contrast", value: $adjustments.contrast, range: -1...1, unit: "", format: percent)
                ValueSlider(label: "Saturation", value: $adjustments.saturation, range: -1...1, unit: "", format: percent)
                ValueSlider(label: "Warmth", value: $adjustments.warmth, range: -1...1, unit: "", format: percent)
                ValueSlider(label: "Sharpness", value: $adjustments.sharpness, range: 0...2, unit: "", format: { String(format: "%.1f", $0) })
                ValueSlider(label: "Vignette", value: $adjustments.vignette, range: 0...2, unit: "", format: { String(format: "%.1f", $0) })
                ControlRow(label: "Orientation") {
                    HStack(spacing: 6) {
                        iconButton("rotate.left") { adjustments.quarterTurns -= 1 }
                        iconButton("rotate.right") { adjustments.quarterTurns += 1 }
                        iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right") { adjustments.flipped.toggle() }
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Button("Reset") { withAnimation { adjustments = Adjustments() } }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .task(id: adjustments) {
            let out = adjustments.apply(to: previewSource)
            rendered = Self.context.createCGImage(out, from: out.extent)
        }
    }

    private func signed1(_ v: Double) -> String { String(format: "%+.1f", v) }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let out = adjustments.apply(to: CIImage(cgImage: image))
        guard let cg = Self.context.createCGImage(out, from: out.extent) else { return }
        Editors.save(cg, from: url, suffix: "Edited", close: close)
    }
}
