import AVFoundation
import ImageIO
import PDFKit
import SwiftUI

struct MetadataRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct MetadataSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [MetadataRow]
}

enum MetadataReader {
    static func file(_ url: URL) -> MetadataSection {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        var rows = [MetadataRow(key: "Name", value: url.lastPathComponent)]
        if let t = values?.localizedTypeDescription { rows.append(MetadataRow(key: "Kind", value: t)) }
        if let s = values?.fileSize { rows.append(MetadataRow(key: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))) }
        if let d = values?.creationDate { rows.append(MetadataRow(key: "Created", value: d.formatted(date: .abbreviated, time: .shortened))) }
        if let d = values?.contentModificationDate { rows.append(MetadataRow(key: "Modified", value: d.formatted(date: .abbreviated, time: .shortened))) }
        return MetadataSection(title: "File", rows: rows)
    }

    static func image(_ url: URL) -> [MetadataSection] {
        let p = ImageIOUtil.properties(url)
        var image: [MetadataRow] = []
        if let w = p[kCGImagePropertyPixelWidth], let h = p[kCGImagePropertyPixelHeight] {
            image.append(MetadataRow(key: "Dimensions", value: "\(w) × \(h) px"))
        }
        if let d = p[kCGImagePropertyDPIWidth] as? Double { image.append(MetadataRow(key: "Resolution", value: "\(Int(d)) dpi")) }
        if let m = p[kCGImagePropertyColorModel] { image.append(MetadataRow(key: "Color model", value: "\(m)")) }
        if let prof = p[kCGImagePropertyProfileName] { image.append(MetadataRow(key: "Profile", value: "\(prof)")) }
        if let depth = p[kCGImagePropertyDepth] { image.append(MetadataRow(key: "Bit depth", value: "\(depth)")) }
        if let a = p[kCGImagePropertyHasAlpha] as? Bool { image.append(MetadataRow(key: "Alpha", value: a ? "Yes" : "No")) }

        var camera: [MetadataRow] = []
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let v = tiff[kCGImagePropertyTIFFMake] { camera.append(MetadataRow(key: "Make", value: "\(v)")) }
        if let v = tiff[kCGImagePropertyTIFFModel] { camera.append(MetadataRow(key: "Model", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifLensModel] { camera.append(MetadataRow(key: "Lens", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifFocalLength] as? Double { camera.append(MetadataRow(key: "Focal length", value: "\(Int(v)) mm")) }
        if let v = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(MetadataRow(key: "Aperture", value: String(format: "ƒ/%.1f", v))) }
        if let v = exif[kCGImagePropertyExifExposureTime] as? Double {
            camera.append(MetadataRow(key: "Shutter", value: v < 1 ? "1/\(Int((1 / v).rounded())) s" : "\(v) s"))
        }
        if let v = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(MetadataRow(key: "ISO", value: "\(v)")) }
        if let v = exif[kCGImagePropertyExifDateTimeOriginal] { camera.append(MetadataRow(key: "Taken", value: "\(v)")) }
        if let v = tiff[kCGImagePropertyTIFFSoftware] { camera.append(MetadataRow(key: "Software", value: "\(v)")) }

        var location: [MetadataRow] = []
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            location.append(MetadataRow(key: "Coordinates", value: String(format: "%.5f° %@, %.5f° %@", lat, ns, lon, ew)))
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { location.append(MetadataRow(key: "Altitude", value: "\(Int(alt)) m")) }
        }

        var sections = [file(url), MetadataSection(title: "Image", rows: image)]
        if !camera.isEmpty { sections.append(MetadataSection(title: "Camera", rows: camera)) }
        if !location.isEmpty { sections.append(MetadataSection(title: "Location", rows: location)) }
        return sections
    }

    static func pdf(_ url: URL) -> [MetadataSection] {
        guard let doc = PDFDocument(url: url) else { return [file(url)] }
        var rows: [MetadataRow] = [MetadataRow(key: "Pages", value: "\(doc.pageCount)")]
        if let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            rows.append(MetadataRow(key: "Page size", value: "\(Int(b.width)) × \(Int(b.height)) pt"))
        }
        rows.append(MetadataRow(key: "Version", value: "\(doc.majorVersion).\(doc.minorVersion)"))
        rows.append(MetadataRow(key: "Encrypted", value: doc.isEncrypted ? "Yes" : "No"))
        let attrs = doc.documentAttributes ?? [:]
        let keys: [(PDFDocumentAttribute, String)] = [(.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
                                                     (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"),
                                                     (.creationDateAttribute, "Created"), (.modificationDateAttribute, "Modified")]
        var info: [MetadataRow] = []
        for (key, label) in keys {
            guard let v = attrs[key] else { continue }
            let text = (v as? Date)?.formatted(date: .abbreviated, time: .shortened) ?? "\(v)"
            if !text.isEmpty { info.append(MetadataRow(key: label, value: text)) }
        }
        var sections = [file(url), MetadataSection(title: "Document", rows: rows)]
        if !info.isEmpty { sections.append(MetadataSection(title: "Info", rows: info)) }
        return sections
    }

    static func media(_ url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)
        var rows: [MetadataRow] = []
        if let d = try? await asset.load(.duration).seconds, d.isFinite {
            rows.append(MetadataRow(key: "Duration", value: Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, transform) = try? await v.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                rows.append(MetadataRow(key: "Dimensions", value: "\(Int(abs(r.width))) × \(Int(abs(r.height)))"))
            }
            if let fps = try? await v.load(.nominalFrameRate), fps > 0 { rows.append(MetadataRow(key: "Frame rate", value: String(format: "%.2f fps", fps))) }
            if let rate = try? await v.load(.estimatedDataRate), rate > 0 { rows.append(MetadataRow(key: "Video bitrate", value: "\(Int(rate / 1000)) kbps")) }
            if let desc = try? await v.load(.formatDescriptions).first { rows.append(MetadataRow(key: "Video codec", value: fourCC(CMFormatDescriptionGetMediaSubType(desc)))) }
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio).first,
           let desc = try? await a.load(.formatDescriptions).first {
            rows.append(MetadataRow(key: "Audio codec", value: fourCC(CMFormatDescriptionGetMediaSubType(desc))))
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                rows.append(MetadataRow(key: "Sample rate", value: "\(Int(asbd.mSampleRate)) Hz"))
                rows.append(MetadataRow(key: "Channels", value: "\(asbd.mChannelsPerFrame)"))
            }
        }
        var tags: [MetadataRow] = []
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue, let value = try? await item.load(.stringValue) else { continue }
                tags.append(MetadataRow(key: key.capitalized, value: value))
            }
        }
        var sections = [file(url), MetadataSection(title: "Media", rows: rows)]
        if !tags.isEmpty { sections.append(MetadataSection(title: "Tags", rows: tags)) }
        return sections
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xff))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

struct MetadataEditor: View {
    let url: URL
    let close: () -> Void

    @State private var sections: [MetadataSection] = []

    private var kind: FileKind { FileKind.of(url) }
    private var hasLocation: Bool { sections.contains { $0.title == "Location" } }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(section.title.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.ink.opacity(0.5))
                                .padding(.leading, 4)
                                .padding(.bottom, 6)
                            VStack(spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(row.key).foregroundStyle(Theme.ink.opacity(0.6))
                                        Spacer(minLength: 16)
                                        Text(row.value)
                                            .foregroundStyle(Theme.ink)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    if i < section.rows.count - 1 {
                                        Divider().overlay(Theme.ink.opacity(0.05)).padding(.leading, 14)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.5)))
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            if kind == .image || kind == .pdf {
                HStack {
                    if hasLocation {
                        Button("Remove Location") { strip(locationOnly: true) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                    Button("Strip All Metadata") { strip(locationOnly: false) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 22)
        .task {
            switch kind {
            case .image: sections = MetadataReader.image(url)
            case .pdf: sections = MetadataReader.pdf(url)
            case .video, .audio: sections = await MetadataReader.media(url)
            default: sections = [MetadataReader.file(url)]
            }
        }
    }

    private func strip(locationOnly: Bool) {
        do {
            let out: URL
            if kind == .pdf {
                guard let doc = PDFDocument(url: url) else { throw OrbitError("Can’t open the PDF") }
                doc.documentAttributes = [:]
                out = Naming.output(for: url, suffix: "Clean", ext: "pdf")
                guard doc.write(to: out) else { throw OrbitError("Couldn’t save the PDF") }
            } else if locationOnly {
                out = Naming.output(for: url, suffix: "No Location", ext: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
                      let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw OrbitError("Can’t read the image") }
                let opts = [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary
                guard CGImageDestinationCopyImageSource(dest, src, opts, nil) else { throw OrbitError("Couldn’t remove the location") }
            } else {
                let image = try ImageIOUtil.load(url)
                let ext = ImageIOUtil.editedExt(for: url)
                out = Naming.output(for: url, suffix: "Clean", ext: ext)
                try ImageIOUtil.write(image, to: out, ext: ext, quality: 0.95)
            }
            close()
            HUD.shared.flash(title: "Saved", detail: "“\(out.lastPathComponent)”", outputs: [out])
        } catch {
            HUD.shared.fail(error)
        }
    }
}
