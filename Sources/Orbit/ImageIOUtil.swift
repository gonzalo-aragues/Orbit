import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageIOUtil {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Loads the first frame with its EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OrbitError("Can’t read “\(url.lastPathComponent)”")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if w > 0, let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        throw OrbitError("“\(url.lastPathComponent)” isn’t an image I can read")
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func dpi(_ url: URL) -> CGFloat {
        let props = properties(url)
        let d = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return d > 0 ? CGFloat(d) : 72
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func uti(for ext: String) -> String? {
        switch ext {
        case "jpg", "jpeg": UTType.jpeg.identifier
        case "png": UTType.png.identifier
        case "heic", "heif": UTType.heic.identifier
        case "tiff", "tif": UTType.tiff.identifier
        case "avif": "public.avif"
        case "bmp": UTType.bmp.identifier
        case "gif": UTType.gif.identifier
        default: nil
        }
    }

    /// The format an edited copy of `source` should be saved in.
    static func editedExt(for source: URL) -> String {
        let ext = Menus.normalizedExt(source)
        if ext == "webp" || uti(for: ext) != nil { return ext == "gif" ? "png" : ext }
        return "png"
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.92, dpi: CGFloat = 72) throws {
        switch ext {
        case "webp":
            guard let data = WebPEncoder.encode(image) else { throw OrbitError("WebP encoding failed") }
            try data.write(to: url)
        case "pdf":
            try writePDF(image, to: url, dpi: dpi)
        default:
            guard let uti = uti(for: ext) else { throw OrbitError("Can’t write \(ext.uppercased())") }
            var img = image
            if ["jpg", "jpeg", "bmp"].contains(ext), hasAlpha(img) { img = flatten(img) ?? img }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
                throw OrbitError("Can’t write \(ext.uppercased())")
            }
            var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            if dpi != 72 { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw OrbitError("Couldn’t save \(ext.uppercased())") }
        }
    }

    static func writePDF(_ image: CGImage, to url: URL, dpi: CGFloat) throws {
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OrbitError("Couldn’t create PDF") }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func flatten(_ img: CGImage, color: CGColor = .white) -> CGImage? {
        guard let ctx = context(width: img.width, height: img.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    static func downscale(_ img: CGImage, maxDimension: Int) -> CGImage? {
        let longest = max(img.width, img.height)
        guard longest > maxDimension else { return img }
        let s = CGFloat(maxDimension) / CGFloat(longest)
        let w = max(1, Int((CGFloat(img.width) * s).rounded())), h = max(1, Int((CGFloat(img.height) * s).rounded()))
        guard let ctx = context(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Text recognition

    struct TextLine {
        let text: String
        /// Normalised, bottom-left origin (Vision coordinates).
        let box: CGRect
    }

    static func recognizeText(_ image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return TextLine(text: text, box: obs.boundingBox)
        }
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
