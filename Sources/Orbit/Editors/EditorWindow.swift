import AppKit
import SwiftUI

final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum Editors {
    private static var windows: [NSWindow] = []

    static func open(_ tool: Tool, url: URL, near point: NSPoint?) {
        if tool == .metadata {
            present(title: "Metadata", size: CGSize(width: 480, height: 620)) { close in
                MetadataEditor(url: url, close: close)
            }
            return
        }
        let image: CGImage
        do { image = try ImageIOUtil.load(url) } catch { HUD.shared.fail(error, at: point); return }
        switch tool {
        case .crop:
            present(title: "Crop Image", size: CGSize(width: 560, height: 800)) { close in
                CropEditor(url: url, image: image, close: close)
            }
        case .addBackground:
            present(title: "Add BG", size: CGSize(width: 580, height: 840)) { close in
                BackgroundEditor(url: url, image: image, close: close)
            }
        case .edit:
            present(title: "Edit Image", size: CGSize(width: 560, height: 820)) { close in
                AdjustEditor(url: url, image: image, close: close)
            }
        case .annotate:
            present(title: "Annotate", size: CGSize(width: 640, height: 800)) { close in
                AnnotateEditor(url: url, image: image, close: close)
            }
        case .redact:
            present(title: "Redact", size: CGSize(width: 600, height: 800)) { close in
                RedactEditor(url: url, image: image, close: close)
            }
        default:
            break
        }
    }

    static func present<Content: View>(title: String, size: CGSize,
                                       @ViewBuilder content: (@escaping () -> Void) -> Content) {
        let window = GlassWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.appearance = NSAppearance(named: .aqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let close: () -> Void = { [weak window] in
            guard let window else { return }
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
        let host = NSHostingView(rootView: EditorShell(title: title, onClose: close) { content(close) })
        host.sizingOptions = []
        window.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let h = min(size.height, vf.height - 20)
            window.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - h / 2, width: size.width, height: h), display: true)
        }
        windows.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { window.invalidateShadow() }
    }

    /// Writes an edited image next to the original and shows the toast.
    static func save(_ image: CGImage, from url: URL, suffix: String, ext: String? = nil, close: () -> Void) {
        let ext = ext ?? ImageIOUtil.editedExt(for: url)
        let out = Naming.output(for: url, suffix: suffix, ext: ext)
        do {
            try ImageIOUtil.write(image, to: out, ext: ext, quality: 0.95)
            close()
            HUD.shared.flash(title: "Saved", detail: "“\(out.lastPathComponent)”", outputs: [out])
        } catch {
            HUD.shared.fail(error)
        }
    }
}

struct EditorShell<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.4)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(shape.fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.2)],
                                               startPoint: .top, endPoint: .bottom)))
        .glassEffect(.regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.5), lineWidth: 1))
        .environment(\.colorScheme, .light)
        .tint(Theme.accent)
    }
}

// MARK: - Controls

struct PillPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = option.0 } } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Theme.ink.opacity(0.8))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Theme.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.4)))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentLight, Theme.accent], startPoint: .top, endPoint: .bottom)))
            .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(0.8))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.45)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .frame(width: 90, alignment: .leading)
            content
        }
    }
}

struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "px"
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        ControlRow(label: label) {
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text("\(format(value)) \(unit)".trimmingCharacters(in: .whitespaces))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink.opacity(0.6))
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct PreviewWell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }
}

/// Where an image of `size` lands when fitted into `bounds`.
func fitRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let s = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}
