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
                Toggle("Show in Dock", isOn: Binding(get: { model.showInDock }, set: { model.showInDock = $0 }))
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
        // a Dock icon and a menu bar, unless Show in Dock is off (also when
        // launched with `swift run`, which has no app bundle)
        AppModel.applyDockPolicy(AppModel.showsInDock)
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

    /// The main window: the sky runs under a see-through title bar, so no
    /// strip is drawn at the top (in full screen too)
    func adopt(_ w: NSWindow) {
        guard window !== w else { return }
        window = w
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.backgroundColor = NSColor(srgbRed: Tokens.bg.r, green: Tokens.bg.g, blue: Tokens.bg.b, alpha: 1)
        w.collectionBehavior.insert(.fullScreenPrimary)
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    /// the window is the desktop picture right now
    var isWallpaper: Bool { saved != nil }

    /// no full screen while the window is the desktop picture
    func toggleFullScreen() {
        guard !isWallpaper else { return }
        window?.toggleFullScreen(nil)
    }

    @ObservationIgnored private var exitObserver: NSObjectProtocol?

    func set(_ on: Bool) {
        guard let w = window else { return }
        // turned off again while still leaving full screen: stay a window
        if !on, let o = exitObserver {
            NotificationCenter.default.removeObserver(o)
            exitObserver = nil
            return
        }
        if on, saved == nil, w.styleMask.contains(.fullScreen) {
            // A full-screen window lives in its own Space: changing it into a
            // borderless desktop window there breaks it. Leave full screen
            // first and become the wallpaper once that's done
            guard exitObserver == nil else { return }
            exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let o = self.exitObserver { NotificationCenter.default.removeObserver(o) }
                    self.exitObserver = nil
                    self.set(true)
                }
            }
            w.toggleFullScreen(nil)
            return
        }
        if on, saved == nil {
            saved = (w.frame, w.styleMask, w.level, w.collectionBehavior)
            w.styleMask = [.borderless, .fullSizeContentView]
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            // .fullScreenNone: the green button and ⌃⌘F can't take it full screen
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
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
