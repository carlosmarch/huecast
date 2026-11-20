import SwiftUI
import AppKit
import HuecastCore

@main
struct HuecastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var desktop = DesktopMode()

    var body: some Scene {
        Window("Huecast", id: "main") {
            ContentView(model: model, desktop: desktop)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Weather") {
                MenuItems(model: model)
                Divider()
                Button("Earlier Hour") { model.select(model.selected - 1) }
                    .keyboardShortcut(.leftArrow)
                Button("Later Hour") { model.select(model.selected + 1) }
                    .keyboardShortcut(.rightArrow)
                Divider()
                Toggle("Temperature in Menu Bar", isOn: Binding(get: { model.menuBarTemperature },
                                                                 set: { model.menuBarTemperature = $0 }))
            }
        }

        // the sky in the menu bar; click it for a small widget that expands
        MenuBarExtra {
            MenuBarWidget(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // launched with `swift run` (no app bundle): still a regular app
        // with a Dock icon and a menu bar
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Turns the window into a live desktop picture: borderless, filling the
/// screen, below the desktop icons and on every Space. The menu bar
/// (Weather > Leave Desktop Wallpaper, ⇧⌘W) brings it back
@MainActor
@Observable
final class DesktopMode {
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var saved: (frame: NSRect, style: NSWindow.StyleMask, level: NSWindow.Level,
                                            behavior: NSWindow.CollectionBehavior)?

    func set(_ on: Bool) {
        guard let w = window else { return }
        if on, saved == nil {
            saved = (w.frame, w.styleMask, w.level, w.collectionBehavior)
            w.styleMask = [.borderless, .fullSizeContentView]
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            if let screen = w.screen ?? NSScreen.main { w.setFrame(screen.frame, display: true) }
        } else if !on, let s = saved {
            saved = nil
            w.styleMask = s.style
            w.level = s.level
            w.collectionBehavior = s.behavior
            w.ignoresMouseEvents = false
            w.setFrame(s.frame, display: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// Hands over the NSWindow a view lives in
struct WindowFinder: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { found(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let w = view.window { found(w) }
    }
}
