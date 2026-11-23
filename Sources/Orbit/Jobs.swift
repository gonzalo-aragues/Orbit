import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

struct JobResult {
    var outputs: [URL]
    var note: String? = nil
}

/// Entry point for everything the ring can do with a dropped file.
@MainActor
enum ActionRunner {
    static func run(_ action: RingAction, files: [URL], near point: NSPoint?) {
        guard !files.isEmpty else { return }
        switch action {
        case .tool(let tool) where tool.opensEditor:
            Editors.open(tool, url: files[0], near: point)
            return
        case .tool(.copyPath):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.flash(title: "Copied Path", detail: files.count == 1 ? files[0].path : "\(files.count) paths", at: point)
            return
        case .convert(.zip):
            HUD.shared.begin(title: action.progressTitle, total: 1, at: point)
            Task {
                do {
                    let out = try await offMain { try Jobs.zip(files) }
                    HUD.shared.update(completed: 1, total: 1)
                    HUD.shared.finish(outputs: [out], errors: [], note: nil)
                } catch {
                    HUD.shared.finish(outputs: [], errors: [error.localizedDescription], note: nil)
                }
            }
            return
        default:
            break
        }

        HUD.shared.begin(title: action.progressTitle, total: files.count, at: point)
        Task {
            var outputs: [URL] = []
            var errors: [String] = []
            var note: String?
            for (i, file) in files.enumerated() {
                do {
                    let result = try await Jobs.perform(action, on: file)
                    outputs += result.outputs
                    if let n = result.note { note = n }
                } catch {
                    errors.append(error.localizedDescription)
                }
                HUD.shared.update(completed: i + 1, total: files.count)
            }
            HUD.shared.finish(outputs: outputs, errors: errors, note: files.count == 1 ? note : nil)
        }
    }
}

func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

enum Jobs {
    static func perform(_ action: RingAction, on url: URL) async throws -> JobResult {
        let kind = FileKind.of(url)
        switch action {
        case .convert(let format):
            switch kind {
            case .image: return JobResult(outputs: [try await offMain { try ImageJobs.convert(url, to: format) }])
            case .pdf: return JobResult(outputs: try await offMain { try PDFJobs.convert(url, to: format) })
            case .video, .audio: return JobResult(outputs: [try await AVJobs.convert(url, to: format)])
            case .document: return JobResult(outputs: [try await DocumentJobs.convert(url, to: format)])
            case .other: return JobResult(outputs: [try await offMain { try zip([url]) }])
            }
        case .tool(.compress):
            switch kind {
            case .image: return try await offMain { try ImageJobs.compress(url) }
            case .pdf: return try await offMain { try PDFJobs.compress(url) }
            case .video: return try await AVJobs.compress(url)
            default: throw OrbitError("Can’t compress this kind of file")
            }
        case .tool(.rotate): return JobResult(outputs: [try await offMain { try PDFJobs.rotate(url) }])
        case .tool(.split): return try await offMain { try PDFJobs.split(url) }
        case .tool(.mute): return JobResult(outputs: [try await AVJobs.mute(url)])
        case .tool(let tool): throw OrbitError("\(tool.title.capitalized) isn’t available here")
        }
    }

    static func zip(_ files: [URL]) throws -> URL {
        guard let first = files.first else { throw OrbitError("Nothing to zip") }
        let dir = first.deletingLastPathComponent()
        let destination = Naming.destination(for: first)
        let process = Process()
        let out: URL
        if files.count == 1 {
            out = Naming.unique(destination.appendingPathComponent(first.lastPathComponent).appendingPathExtension("zip"))
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path]
        } else {
            out = Naming.unique(destination.appendingPathComponent("Archive.zip"))
            let sameFolder = files.allSatisfy { $0.deletingLastPathComponent() == dir }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = dir
            process.arguments = ["-r", "-q", "-X"] + (sameFolder ? [] : ["-j"]) + [out.path]
                + files.map { sameFolder ? $0.lastPathComponent : $0.path }
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OrbitError("Zipping failed") }
        return out
    }

    static func savingsNote(from original: URL, to output: URL) -> String {
        let before = Naming.bytes(original), after = Naming.bytes(output)
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        guard before > 0 else { return "Saved “\(output.lastPathComponent)”" }
        let pct = Int((1 - Double(after) / Double(before)) * 100)
        return "\(fmt(before)) → \(fmt(after)) · \(pct)% smaller"
    }
}

// MARK: - Images

enum ImageJobs {
    static func convert(_ url: URL, to format: Format) throws -> URL {
        let image = try ImageIOUtil.load(url)
        let out = Naming.output(for: url, ext: format.rawValue)
        switch format {
        case .docx:
            let lines = try ImageIOUtil.recognizeText(image)
            guard !lines.isEmpty else { throw OrbitError("No text found in “\(url.lastPathComponent)”") }
            try DocumentJobs.writeDOCX(DocumentJobs.plain(lines.map(\.text).joined(separator: "\n")), to: out)
        case .txt:
            let lines = try ImageIOUtil.recognizeText(image)
            try lines.map(\.text).joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        default:
            try ImageIOUtil.write(image, to: out, ext: format.rawValue, dpi: ImageIOUtil.dpi(url))
        }
        return out
    }

    static func compress(_ url: URL) throws -> JobResult {
        guard var image = try? ImageIOUtil.load(url) else { throw OrbitError("Can’t read “\(url.lastPathComponent)”") }
        image = ImageIOUtil.downscale(image, maxDimension: 4096) ?? image
        let source = Menus.normalizedExt(url)
        let alpha = ImageIOUtil.hasAlpha(image) && imageUsesAlpha(image)
        let ext: String
        switch source {
        case "jpg", "heic", "avif": ext = source
        default: ext = alpha ? "heic" : "jpg"
        }
        let out = Naming.output(for: url, suffix: "Compressed", ext: ext)
        try ImageIOUtil.write(image, to: out, ext: ext, quality: 0.6)
        if Naming.bytes(out) >= Naming.bytes(url) {
            try? FileManager.default.removeItem(at: out)
            return JobResult(outputs: [], note: "Already as small as it gets")
        }
        return JobResult(outputs: [out], note: Jobs.savingsNote(from: url, to: out))
    }

    /// True if any pixel is actually translucent (many PNGs carry an unused alpha channel).
    static func imageUsesAlpha(_ image: CGImage) -> Bool {
        guard let small = ImageIOUtil.downscale(image, maxDimension: 256),
              let ctx = ImageIOUtil.context(width: small.width, height: small.height) else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: small.width, height: small.height))
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        guard let data = ctx.data else { return true }
        let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * small.height)
        for y in 0..<small.height {
            for x in 0..<small.width where p[y * ctx.bytesPerRow + x * 4 + 3] < 250 { return true }
        }
        return false
    }
}

// MARK: - PDF

enum PDFJobs {
    static func document(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw OrbitError("Can’t open “\(url.lastPathComponent)”") }
        if doc.isLocked { throw OrbitError("“\(url.lastPathComponent)” is password protected") }
        return doc
    }

    static func convert(_ url: URL, to format: Format) throws -> [URL] {
        let doc = try document(url)
        switch format {
        case .jpg, .png, .tiff, .heic, .webp:
            guard let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0 else { throw OrbitError("Empty PDF") }
            var outputs: [URL] = []
            for i in 1...cg.numberOfPages {
                guard let page = cg.page(at: i), let image = render(page, dpi: 300) else { continue }
                let out = cg.numberOfPages == 1
                    ? Naming.output(for: url, ext: format.rawValue)
                    : Naming.output(for: url, suffix: "- Page \(i)", ext: format.rawValue)
                try ImageIOUtil.write(image, to: out, ext: format.rawValue, dpi: 300)
                outputs.append(out)
            }
            return outputs
        case .txt:
            let out = Naming.output(for: url, ext: "txt")
            try text(of: doc, url: url).write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case .docx:
            let out = Naming.output(for: url, ext: "docx")
            let rich = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.attributedString, page.length > 0 {
                    if rich.length > 0 { rich.append(NSAttributedString(string: "\n\n")) }
                    rich.append(page)
                }
            }
            let body: NSAttributedString = rich.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? DocumentJobs.plain(try text(of: doc, url: url))
                : DocumentJobs.normalizedColors(rich)
            try DocumentJobs.writeDOCX(body, to: out)
            return [out]
        default:
            throw OrbitError("Can’t convert PDF to \(format.title)")
        }
    }

    /// The PDF's text layer, falling back to OCR for scanned documents.
    static func text(of doc: PDFDocument, url: URL) throws -> String {
        if let s = doc.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        guard let cg = CGPDFDocument(url as CFURL) else { return "" }
        var pages: [String] = []
        for i in 1...max(cg.numberOfPages, 1) {
            guard let page = cg.page(at: i), let image = render(page, dpi: 200) else { continue }
            pages.append(try ImageIOUtil.recognizeText(image).map(\.text).joined(separator: "\n"))
        }
        let s = pages.joined(separator: "\n\n")
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OrbitError("No text found in this PDF") }
        return s
    }

    static func render(_ page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let pointSize = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let w = Int((pointSize.width * scale).rounded()), h = Int((pointSize.height * scale).rounded())
        guard w > 0, h > 0, let ctx = ImageIOUtil.context(width: w, height: h) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pointSize),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func compress(_ url: URL) throws -> JobResult {
        let doc = try document(url)
        let out = Naming.output(for: url, suffix: "Compressed", ext: "pdf")
        let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        guard ok else { throw OrbitError("Couldn’t compress the PDF") }
        if Naming.bytes(out) >= Naming.bytes(url) {
            try? FileManager.default.removeItem(at: out)
            return JobResult(outputs: [], note: "Already as small as it gets")
        }
        return JobResult(outputs: [out], note: Jobs.savingsNote(from: url, to: out))
    }

    static func rotate(_ url: URL) throws -> URL {
        let doc = try document(url)
        for i in 0..<doc.pageCount { doc.page(at: i).map { $0.rotation = ($0.rotation + 90) % 360 } }
        let out = Naming.output(for: url, suffix: "Rotated", ext: "pdf")
        guard doc.write(to: out) else { throw OrbitError("Couldn’t save the PDF") }
        return out
    }

    static func split(_ url: URL) throws -> JobResult {
        let doc = try document(url)
        guard doc.pageCount > 1 else { throw OrbitError("This PDF only has one page") }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = Naming.unique(Naming.destination(for: url).appendingPathComponent("\(base) Pages"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent("\(base) - Page \(i + 1).pdf"))
        }
        return JobResult(outputs: [folder], note: "\(doc.pageCount) pages saved to “\(folder.lastPathComponent)”")
    }
}

// MARK: - Documents

@MainActor
enum DocumentJobs {
    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return parsed.map { normalizedColors(NSAttributedString($0)) } ?? plain(text)
        }
        return normalizedColors(try NSAttributedString(url: url, options: [:], documentAttributes: nil))
    }

    static func convert(_ url: URL, to format: Format) throws -> URL {
        let doc = try load(url)
        let out = Naming.output(for: url, ext: format.rawValue)
        let range = NSRange(location: 0, length: doc.length)
        switch format {
        case .txt: try doc.string.write(to: out, atomically: true, encoding: .utf8)
        case .rtf: try doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: out)
        case .html: try doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: out)
        case .docx: try writeDOCX(doc, to: out)
        case .pdf: try writePDF(doc, to: out)
        default: throw OrbitError("Can’t convert to \(format.title)")
        }
        return out
    }

    nonisolated static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ])
    }

    /// Dynamic colours like `labelColor` turn white in dark mode, so pin text to black.
    nonisolated static func normalizedColors(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            let color = value as? NSColor
            if color == nil || color?.type == .catalog {
                m.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
        return m
    }

    nonisolated static func writeDOCX(_ s: NSAttributedString, to url: URL) throws {
        let data = try s.data(from: NSRange(location: 0, length: s.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
    }

    static func writePDF(_ s: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(s)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.frame.size.height = max(lm.usedRect(for: tc).height + 20, 100)
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw OrbitError("Couldn’t create the PDF") }
    }
}

// MARK: - Audio & video

enum AVJobs {
    static func convert(_ url: URL, to format: Format) async throws -> URL {
        let out = Naming.output(for: url, ext: format.rawValue)
        let asset = AVURLAsset(url: url)
        switch format {
        case .mp4: try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        case .mov: try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: .mov)
        case .m4a: try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a)
        case .gif: try await gif(asset, to: out)
        case .wav, .aiff: try await offMain { try pcm(url, to: out, bigEndian: format == .aiff) }
        default: throw OrbitError("Can’t convert to \(format.title)")
        }
        return out
    }

    static func compress(_ url: URL) async throws -> JobResult {
        let out = Naming.output(for: url, suffix: "Compressed", ext: "mp4")
        try await export(AVURLAsset(url: url), preset: AVAssetExportPreset1280x720, to: out, type: .mp4)
        return JobResult(outputs: [out], note: Jobs.savingsNote(from: url, to: out))
    }

    static func mute(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw OrbitError("No video track found") }
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        track.preferredTransform = try await video.load(.preferredTransform)
        let isMP4 = Menus.normalizedExt(url) == "mp4"
        let out = Naming.output(for: url, suffix: "Muted", ext: isMP4 ? "mp4" : "mov")
        try await export(composition, preset: AVAssetExportPresetPassthrough, to: out, type: isMP4 ? .mp4 : .mov)
        return out
    }

    static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OrbitError("This file can’t be exported that way")
        }
        try await session.export(to: url, as: type)
    }

    static func gif(_ asset: AVURLAsset, to url: URL) async throws {
        let duration = try await asset.load(.duration).seconds
        let fps = 12.0
        let count = max(1, Int(min(duration, 20) * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 540, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw OrbitError("Couldn’t create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var last: CGImage?
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) { last = image }
            guard let frame = last else { continue }
            CGImageDestinationAddImage(dest, frame, frameProps)
        }
        guard last != nil, CGImageDestinationFinalize(dest) else { throw OrbitError("Couldn’t create GIF") }
    }

    static func pcm(_ src: URL, to dst: URL, bigEndian: Bool) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(forWriting: dst, settings: settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw OrbitError("Audio error") }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
