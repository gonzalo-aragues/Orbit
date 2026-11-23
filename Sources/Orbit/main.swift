import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.handle() { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Orbit")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DragMonitor.shared.start()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            HUD.shared.flash(title: "Orbit is running",
                             detail: "Hold ⌥ Option while dragging a file and the ring appears. Press ⇧ or rest in the centre to switch rings.",
                             at: NSPoint(x: NSScreen.main?.frame.midX ?? 600, y: (NSScreen.main?.frame.maxY ?? 800) - 160))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Hold ⌥ while dragging a file to open the ring", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Show Ring While Dragging", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.state = DragMonitor.shared.enabled ? .on : .off
        enabled.target = self
        menu.addItem(enabled)

        let delay = NSMenuItem(title: "Ring Delay", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for (title, value) in [("Instant", 0.12), ("Short", 0.35), ("Long", 0.7)] {
            let item = NSMenuItem(title: title, action: #selector(setDelay(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = abs(DragMonitor.shared.delay - value) < 0.01 ? .on : .off
            item.target = self
            delayMenu.addItem(item)
        }
        delay.submenu = delayMenu
        menu.addItem(delay)

        let desktop = NSMenuItem(title: "Save to Desktop", action: #selector(toggleDesktop), keyEquivalent: "")
        desktop.state = Naming.savesToDesktop ? .on : .off
        desktop.target = self
        menu.addItem(desktop)

        let open = NSMenuItem(title: "Open Ring for File…", action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() { DragMonitor.shared.enabled.toggle() }

    @objc private func toggleDesktop() { Naming.savesToDesktop.toggle() }

    @objc private func setDelay(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { DragMonitor.shared.delay = v }
    }

    @objc private func openFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let f = NSScreen.main?.frame ?? .zero
        RingController.shared.show(files: panel.urls, at: NSPoint(x: f.midX, y: f.midY), mode: .click)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            HUD.shared.fail(error)
        }
    }
}

/// Hidden developer entry points, handy for trying things without dragging:
///   Orbit --ring <file>             show the ring (click mode) in the middle of the screen
///   Orbit --editor <tool> <file>    open an editor (crop, addBackground, edit, annotate, redact, metadata)
///   Orbit --run <action> <file>     run an action headlessly and print the result, e.g. --run jpg Page.pdf
@MainActor
enum CommandLine {
    static func handle() -> Bool {
        let args = Swift.CommandLine.arguments
        if args.count == 2, args[1] == "--launch-at-login" {
            do {
                try SMAppService.mainApp.register()
                print("Launch at Login:", SMAppService.mainApp.status == .enabled ? "enabled" : "needs approval in System Settings › General › Login Items")
            } catch {
                print("ERROR", error.localizedDescription)
            }
            exit(0)
        }
        guard args.count >= 3 else { return false }
        let center: NSPoint = {
            let f = NSScreen.main?.frame ?? .zero
            return NSPoint(x: f.midX, y: f.midY)
        }()
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (n, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let path = out.deletingPathExtension().appendingPathExtension("\(n).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: path)
                    print("snapshot", path.path)
                }
                exit(0)
            }
        }
        switch args[1] {
        case "--ring":
            let urls = args.dropFirst(2).prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            RingController.shared.show(files: urls, at: center, mode: .click)
            if args.contains("--tools") { RingController.shared.togglePage() }
            return true
        case "--editor" where args.count >= 4:
            guard let tool = Tool(rawValue: args[2]) else { return false }
            Editors.open(tool, url: URL(fileURLWithPath: args[3]), near: nil)
            return true
        case "--run" where args.count >= 4:
            let action: RingAction = Format(rawValue: args[2]).map { .convert($0) } ?? .tool(Tool(rawValue: args[2]) ?? .compress)
            let url = URL(fileURLWithPath: args[3])
            Task {
                do {
                    let r = try await Jobs.perform(action, on: url)
                    print("OK", r.outputs.map(\.path), r.note ?? "")
                } catch {
                    print("ERROR", error.localizedDescription)
                }
                exit(0)
            }
            return true
        default:
            return false
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
