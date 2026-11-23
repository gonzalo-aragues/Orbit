import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class HUDModel {
    var title = ""
    var detail = ""
    var progress: Double = 0
    var done = false
    var failed = false
    var outputs: [URL] = []
    var shown = false
}

/// The glass "Converting to JPG · 1 of 1 saved" toast.
@MainActor
final class HUD {
    static let shared = HUD()

    let model = HUDModel()
    private let size = NSSize(width: 460, height: 150)
    private var hideWork: DispatchWorkItem?

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        p.contentView = host
        return p
    }()

    func begin(title: String, total: Int, at point: NSPoint?) {
        hideWork?.cancel()
        model.title = title
        model.detail = "0 of \(total) saved"
        model.done = false
        model.failed = false
        model.outputs = []
        model.progress = 0.04
        present(at: point)
        // Ease the bar along while the first file works, so it never looks stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !self.model.done else { return }
            withAnimation(.easeOut(duration: 6)) { self.model.progress = 0.8 / Double(max(total, 1)) }
        }
    }

    func update(completed: Int, total: Int) {
        model.detail = "\(completed) of \(total) saved"
        withAnimation(.easeOut(duration: 0.3)) { model.progress = Double(completed) / Double(max(total, 1)) }
        if completed < total {
            let next = (Double(completed) + 0.8) / Double(total)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 5)) { self.model.progress = next }
            }
        }
    }

    func finish(outputs: [URL], errors: [String], note: String?) {
        model.outputs = outputs
        model.done = true
        withAnimation(.easeOut(duration: 0.25)) { model.progress = 1 }
        if !errors.isEmpty && outputs.isEmpty {
            model.failed = true
            model.detail = errors.first ?? "Something went wrong"
        } else if !errors.isEmpty {
            model.detail = "\(outputs.count) saved · \(errors.count) failed"
        } else if let note {
            model.detail = note
        } else if outputs.count == 1 {
            model.detail = "Saved “\(outputs[0].lastPathComponent)”"
        }
        scheduleHide(after: model.failed ? 5 : 3.2)
    }

    func flash(title: String, detail: String, outputs: [URL] = [], failed: Bool = false, at point: NSPoint? = nil) {
        hideWork?.cancel()
        model.title = title
        model.detail = detail
        model.outputs = outputs
        model.done = true
        model.failed = failed
        model.progress = 1
        present(at: point)
        scheduleHide(after: failed ? 5 : 3)
    }

    func fail(_ error: Error, at point: NSPoint? = nil) {
        flash(title: "Couldn’t do that", detail: error.localizedDescription, failed: true, at: point)
    }

    func hide() {
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.18)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !self.model.shown { self.panel.orderOut(nil) }
        }
    }

    func reveal() {
        if model.outputs.isEmpty { return }
        NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
        hide()
    }

    private func present(at point: NSPoint?) {
        let mouse = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        let wasVisible = panel.isVisible && model.shown
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if !wasVisible {
            model.shown = false
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { self.model.shown = true }
            }
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

private struct HUDView: View {
    let model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button { HUD.shared.hide() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(model.title)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if model.done && !model.outputs.isEmpty {
                    Button("Show") { HUD.shared.reveal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentDeep)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.5)))
                }
            }

            Text(model.detail)
                .font(.system(size: 15))
                .foregroundStyle(model.failed ? Color.red.opacity(0.75) : Theme.ink.opacity(0.5))
                .lineLimit(2)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.1))
                    Capsule()
                        .fill(model.failed ? Color.red.opacity(0.7) : Theme.accent)
                        .frame(width: max(6, geo.size.width * model.progress))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.22)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { HUD.shared.reveal() }
        .scaleEffect(model.shown ? 1 : 0.9)
        .opacity(model.shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
    }
}
