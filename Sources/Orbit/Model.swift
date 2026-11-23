import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.97, green: 0.37, blue: 0.13)
    static let accentLight = Color(red: 1.0, green: 0.50, blue: 0.24)
    static let accentDeep = Color(red: 0.90, green: 0.25, blue: 0.09)
    static let ink = Color(red: 0.22, green: 0.19, blue: 0.18)
    static let inkSoft = Color(red: 0.22, green: 0.19, blue: 0.18).opacity(0.6)
}

// MARK: - File kinds

enum FileKind: Hashable {
    case image, pdf, video, audio, document, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm", "odt", "webarchive"].contains(ext) {
            return .document
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .document }
        return .other
    }

    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.of))
        guard kinds.count == 1, let kind = kinds.first else { return .other }
        return kind
    }
}

// MARK: - Actions

enum Format: String, CaseIterable {
    case jpg, png, webp, heic, tiff, avif, bmp, gif, pdf, docx, txt, rtf, html, mp4, mov, m4a, wav, aiff, zip

    var title: String { rawValue.uppercased() }
}

enum Tool: String {
    case compress, metadata, edit, annotate, addBackground, crop, redact, rotate, split, mute, copyPath

    var title: String {
        switch self {
        case .compress: "COMPRESS"
        case .metadata: "METADATA"
        case .edit: "EDIT"
        case .annotate: "ANNOTATE"
        case .addBackground: "ADD BG"
        case .crop: "CROP"
        case .redact: "REDACT"
        case .rotate: "ROTATE"
        case .split: "SPLIT"
        case .mute: "MUTE"
        case .copyPath: "COPY PATH"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .metadata: "tag"
        case .edit: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .addBackground: "photo"
        case .crop: "crop"
        case .redact: "eye.slash"
        case .rotate: "rotate.right"
        case .split: "square.split.2x1"
        case .mute: "speaker.slash"
        case .copyPath: "doc.on.clipboard"
        }
    }

    /// Tools that open an editor window instead of running straight away.
    var opensEditor: Bool {
        switch self {
        case .metadata, .edit, .annotate, .addBackground, .crop, .redact: true
        default: false
        }
    }
}

enum RingAction: Hashable {
    case convert(Format)
    case tool(Tool)

    var progressTitle: String {
        switch self {
        case .convert(.zip): "Zipping"
        case .convert(let f): "Converting to \(f.title)"
        case .tool(.compress): "Compressing"
        case .tool(.rotate): "Rotating"
        case .tool(.split): "Splitting Pages"
        case .tool(.mute): "Removing Audio"
        case .tool(let t): t.title.capitalized
        }
    }
}

struct RingItem: Identifiable, Hashable {
    let action: RingAction
    var id: RingAction { action }

    var title: String {
        switch action {
        case .convert(let f): f.title
        case .tool(let t): t.title
        }
    }

    var symbol: String? {
        if case .tool(let t) = action { return t.symbol }
        return nil
    }
}

// MARK: - Menus

enum Menus {
    static func convert(for urls: [URL]) -> [RingItem] {
        let kind = FileKind.common(urls)
        let ext = urls.first.map { normalizedExt($0) } ?? ""
        let formats: [Format]
        switch kind {
        case .image: formats = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx]
        case .pdf: formats = [.docx, .jpg, .png, .txt]
        case .video: formats = [.mp4, .mov, .gif, .m4a]
        case .audio: formats = [.m4a, .wav, .aiff]
        case .document: formats = [.pdf, .docx, .txt, .rtf, .html]
        case .other: formats = [.zip]
        }
        var list = formats.filter { $0.rawValue != ext }
        if kind == .image { list = Array(list.prefix(8)) }
        var items = list.map { RingItem(action: .convert($0)) }
        if kind == .other { items.append(RingItem(action: .tool(.copyPath))) }
        return items
    }

    static func tools(for urls: [URL]) -> [RingItem] {
        let tools: [Tool]
        switch FileKind.common(urls) {
        case .image: tools = [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
        case .pdf: tools = [.compress, .metadata, .rotate, .split]
        case .video: tools = [.compress, .metadata, .mute]
        case .audio, .document: tools = [.metadata, .copyPath]
        case .other: tools = []
        }
        return tools.map { RingItem(action: .tool($0)) }
    }

    static func normalizedExt(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg", "jpe": "jpg"
        case "tif": "tiff"
        case "heif": "heic"
        case "aif": "aiff"
        case "htm": "html"
        case let e: e
        }
    }
}

// MARK: - Errors & naming

struct OrbitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Naming {
    /// "Page 001.pdf" + suffix "Cropped" + ext "jpg" -> "Page 001 Cropped.jpg", never overwriting.
    /// New files land on the Desktop unless "Save to Desktop" is switched off in the menu.
    static var savesToDesktop: Bool {
        get { UserDefaults.standard.object(forKey: "savesToDesktop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "savesToDesktop") }
    }

    static func destination(for source: URL) -> URL {
        if savesToDesktop, let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop
        }
        return source.deletingLastPathComponent()
    }

    static func output(for source: URL, suffix: String? = nil, ext: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? destination(for: source)
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { base += " \(suffix)" }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func sizeString(_ urls: [URL]) -> String {
        if urls.count > 1 { return "\(urls.count) FILES" }
        guard let url = urls.first else { return "" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return "FOLDER" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func bytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
