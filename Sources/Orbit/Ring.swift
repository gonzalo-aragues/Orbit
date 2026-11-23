import AppKit
import Observation
import SwiftUI

enum RingPage { case convert, tools }

enum RingHover: Equatable {
    case none, hub, item(Int)
    var isItem: Bool { if case .item = self { true } else { false } }
}

enum RingMode { case drag, click }

@MainActor @Observable
final class RingModel {
    var convertItems: [RingItem] = []
    var toolItems: [RingItem] = []
    var page: RingPage = .convert
    var hover: RingHover = .none
    var shown = false
    var committing = false
    var dwell: Double = 0
    var sizeText = ""

    var items: [RingItem] { page == .convert ? convertItems : toolItems }
    var canToggle: Bool { !convertItems.isEmpty && !toolItems.isEmpty }

    var hubText: String {
        if case .item(let i) = hover, i < items.count { return items[i].title }
        if hover == .hub, dwell > 0 { return page == .convert ? "TOOLS" : "CONVERT" }
        return sizeText
    }
}

final class RingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: RingGeometry.size, height: RingGeometry.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
}

/// Receives the file drop (and clicks, in click mode) for the whole ring.
final class RingDropView: NSView {
    private let host: NSHostingView<RingView>

    init(model: RingModel) {
        host = NSHostingView(rootView: RingView(model: model))
        super.init(frame: NSRect(x: 0, y: 0, width: RingGeometry.size, height: RingGeometry.size))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    private var controller: RingController { RingController.shared }

    private func offset(_ windowPoint: NSPoint) -> (CGFloat, CGFloat) {
        let p = convert(windowPoint, from: nil)
        return (p.x - bounds.midX, p.y - bounds.midY)
    }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let (dx, dy) = offset(sender.draggingLocation)
        controller.setHover(dx: dx, dy: dy)
        return controller.model.hover.isItem ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller.setHover(.none) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller.model.hover.isItem }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return controller.commit(files: urls)
    }

    override func mouseDown(with event: NSEvent) {
        let (dx, dy) = offset(event.locationInWindow)
        controller.click(dx: dx, dy: dy)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller.hide()                // esc
        case 48, 49: controller.togglePage()       // tab, space
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class RingController {
    static let shared = RingController()

    let model = RingModel()
    private lazy var panel: RingPanel = {
        let p = RingPanel()
        p.contentView = RingDropView(model: model)
        return p
    }()
    private var timer: Timer?
    private var files: [URL] = []
    private var mode: RingMode = .drag
    private var center: NSPoint = .zero
    private var leftHub = false
    private var shiftWasDown = false
    private var lastTick = Date()
    private var hiding = false
    private var committed = false
    private var mouseReleasedAt: Date?

    var isVisible: Bool { panel.isVisible && !hiding }

    func show(files: [URL], at point: NSPoint, mode: RingMode) {
        self.files = files
        self.mode = mode
        hiding = false
        committed = false
        mouseReleasedAt = nil
        model.convertItems = Menus.convert(for: files)
        model.toolItems = Menus.tools(for: files)
        model.page = model.convertItems.isEmpty ? .tools : .convert
        model.hover = mode == .drag ? .hub : .none
        model.dwell = 0
        model.committing = false
        model.sizeText = Naming.sizeString(files)
        leftHub = false
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)

        let size = RingGeometry.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vf = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size)
        center = NSPoint(x: origin.x + size / 2, y: origin.y + size / 2)

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        model.shown = false
        panel.orderFrontRegardless()
        if mode == .click {
            NSApp.activate()
            panel.makeKey()
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) { self.model.shown = true }
        }
        startTimer()
    }

    func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        timer?.invalidate()
        timer = nil
        withAnimation(.easeIn(duration: 0.16)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard self.hiding else { return }
            self.panel.orderOut(nil)
            self.hiding = false
            self.model.hover = .none
        }
    }

    func togglePage() {
        guard model.canToggle else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            model.page = model.page == .convert ? .tools : .convert
            model.dwell = 0
        }
        updateHoverFromMouse()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func setHover(_ hover: RingHover) {
        guard hover != model.hover else { return }
        if hover.isItem { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        if hover != .hub && hover != .none { leftHub = true }
        if hover != .hub { model.dwell = 0 }
        model.hover = hover
    }

    func setHover(dx: CGFloat, dy: CGFloat) {
        setHover(RingGeometry.hover(dx: dx, dy: dy, count: model.items.count))
    }

    /// Called when a file is dropped on the ring.
    func commit(files dropped: [URL]) -> Bool {
        guard case .item(let index) = model.hover, index < model.items.count else { return false }
        let action = model.items[index].action
        let targets = dropped.isEmpty ? files : dropped
        NSLog("Orbit: dropped on %@", model.items[index].title)
        finish(with: action, files: targets)
        return true
    }

    func click(dx: CGFloat, dy: CGFloat) {
        switch RingGeometry.hover(dx: dx, dy: dy, count: model.items.count) {
        case .hub: togglePage()
        case .none: hide()
        case .item(let index):
            finish(with: model.items[index].action, files: files)
        }
    }

    private func finish(with action: RingAction, files: [URL]) {
        committed = true
        hiding = true
        timer?.invalidate()
        timer = nil
        let point = center
        withAnimation(.easeOut(duration: 0.2)) {
            model.committing = true
            model.shown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            self.panel.orderOut(nil)
            self.hiding = false
            self.model.hover = .none
        }
        DispatchQueue.main.async {
            ActionRunner.run(action, files: files, near: point)
        }
    }

    // MARK: - Tracking

    private func startTimer() {
        timer?.invalidate()
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func updateHoverFromMouse() {
        let m = NSEvent.mouseLocation
        setHover(dx: m.x - center.x, dy: -(m.y - center.y))
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift && !shiftWasDown { togglePage() }
        shiftWasDown = shift

        let m = NSEvent.mouseLocation
        let distance = hypot(m.x - center.x, m.y - center.y)

        if mode == .drag {
            // Let drops pass through outside the disc, and get out of the way if the user drags elsewhere.
            panel.ignoresMouseEvents = distance > RingGeometry.disk
            if distance > RingGeometry.disk + 150 { hide(); return }
            // The ring lives only while ⌥ is held: letting go mid-drag dismisses it (press again to bring it back).
            if !NSEvent.modifierFlags.contains(.option), NSEvent.pressedMouseButtons & 1 != 0, !committed {
                hide()
                DragMonitor.shared.allowRetrigger()
                return
            }
            updateHoverFromMouse()
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if mouseReleasedAt == nil { mouseReleasedAt = now }
                // Give performDragOperation a moment to land before we tidy up.
                if let released = mouseReleasedAt, now.timeIntervalSince(released) > 0.25, !committed { hide(); return }
            }
        } else {
            updateHoverFromMouse()
        }

        if model.hover == .hub, leftHub, model.canToggle {
            model.dwell = min(1, model.dwell + dt / 0.6)
            if model.dwell >= 1 {
                leftHub = false
                togglePage()
            }
        } else if model.dwell != 0, model.hover != .hub {
            model.dwell = 0
        }
    }
}

// MARK: - Global drag detection

@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "disabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "disabled") }
    }

    var delay: Double {
        get { UserDefaults.standard.object(forKey: "delay") as? Double ?? 0.12 }
        set { UserDefaults.standard.set(newValue, forKey: "delay") }
    }

    private var monitors: [Any] = []
    private var changeCountAtMouseDown = 0
    private var firstSeen: Date?
    private var handledThisDrag = false

    func start() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { DragMonitor.shared.mouseDown() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { _ in
            MainActor.assumeIsolated { DragMonitor.shared.mouseDragged() }
        }) { monitors.append(m) }
    }

    private func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        firstSeen = nil
        handledThisDrag = false
    }

    /// Called when the ring was dismissed by releasing ⌥, so pressing it again in the same drag reopens it.
    func allowRetrigger() {
        handledThisDrag = false
        firstSeen = nil
    }

    private func mouseDragged() {
        guard enabled, !handledThisDrag, !RingController.shared.isVisible else { return }
        // Only while ⌥ Option is held, so ordinary drags are left alone.
        guard NSEvent.modifierFlags.contains(.option) else { firstSeen = nil; return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != changeCountAtMouseDown else { return }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let now = Date()
        if firstSeen == nil { firstSeen = now }
        guard let first = firstSeen, now.timeIntervalSince(first) >= delay else { return }
        handledThisDrag = true
        NSLog("Orbit: ring for %@", urls.map(\.lastPathComponent).joined(separator: ", "))
        RingController.shared.show(files: urls, at: NSEvent.mouseLocation, mode: .drag)
    }
}
