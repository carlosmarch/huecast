import SwiftUI
import AppKit
import HuecastCore

/// The clock the particles, the sun's pulses, the moon and the halo run on.
/// Normally the real time; while recording, a virtual time that steps one
/// frame at a time, so a video plays smoothly however long each frame
/// takes to capture
/// Observable, so each step invalidates the views that read it: a timeline
/// doesn't tick on its own while frames are captured one by one
@MainActor
@Observable
final class AnimationClock {
    static let shared = AnimationClock()
    var virtual: Double?

    static func time(_ date: Date) -> Double {
        shared.virtual ?? date.timeIntervalSinceReferenceDate
    }
}

/// Video mode, used by CI: `-record <dir> -shots widget,window,wallpaper`
/// (with `-demo …`). Records each shot as a numbered JPEG sequence at 30
/// frames a second of animation time, in `<dir>/<shot>/`:
///
/// - widget: the menu bar widget, at 4x
/// - window: the window at 2x; with `-scrub` it drags through the
///   forecast hours like a pointer would
/// - wallpaper: Huecast as the desktop picture, 1440x900 at 1.5x
///
/// Also saves the menu bar icon for the sky as `menubar-icon.png`.
/// Writes `<dir>/finished` and quits when done
@MainActor
enum Recorder {
    static let directory: URL? = AppModel.argument("-record").map { URL(fileURLWithPath: $0) }
    static let fps = 30.0
    private static var ran = false
    nonisolated private static let writer = DispatchQueue(label: "recorder.writer", qos: .userInitiated)
    nonisolated private static let pending = DispatchGroup()

    static func run(_ model: AppModel) {
        guard let dir = directory, !ran else { return }
        ran = true
        let shots = (AppModel.argument("-shots") ?? "widget,window,wallpaper").split(separator: ",").map(String.init)
        let seconds = AppModel.argument("-seconds").flatMap { Double($0) } ?? 6
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Task {
            // the menu bar icon for this sky, for every scene
            if let now = model.forecast?.next.first {
                savePNG(icon(model.sky(for: now)), to: dir.appendingPathComponent("menubar-icon.png"))
            }
            try? await Task.sleep(for: .seconds(3))
            for shot in shots {
                switch shot {
                case "widget": await widget(model, dir, seconds)
                case "window": await window(model, dir, seconds)
                case "wallpaper": await wallpaper(model, dir, seconds)
                default: break
                }
            }
            pending.wait()
            FileManager.default.createFile(atPath: dir.appendingPathComponent("finished").path, contents: nil)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Shots

    private static func widget(_ model: AppModel, _ dir: URL, _ seconds: Double) async {
        toggleStatusItem()
        try? await Task.sleep(for: .seconds(2.5))
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title != "Huecast" && $0.frame.width > 60 && $0.frame.height > 60 })
        else { return }
        await record(w, scale: 4, seconds: seconds, to: dir.appendingPathComponent("widget"))
        toggleStatusItem()
        try? await Task.sleep(for: .seconds(1))
    }

    private static func window(_ model: AppModel, _ dir: URL, _ seconds: Double) async {
        guard let main = await mainWindow(model) else { return }
        main.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: true)
        model.select(0)
        try? await Task.sleep(for: .seconds(2.5))
        let scrub = CommandLine.arguments.contains("-scrub")
        // hold on now, drag through the day to the evening, hold there
        let last = min(16, max(model.hours.count - 1, 0))
        await record(main, scale: 2, seconds: seconds, to: dir.appendingPathComponent("window")) { t in
            guard scrub else { return }
            let start = 1.2, end = seconds - 1.6
            let p = min(max((t - start) / (end - start), 0), 1)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            model.select(Int((eased * Double(last)).rounded()))
        }
        model.select(0)
    }

    private static func wallpaper(_ model: AppModel, _ dir: URL, _ seconds: Double) async {
        guard let main = await mainWindow(model) else { return }
        model.select(0)
        model.wallpaper = true
        try? await Task.sleep(for: .seconds(2))
        main.setFrame(NSRect(origin: .zero, size: Marketing.size), display: true)
        try? await Task.sleep(for: .seconds(2.5))
        await record(main, scale: 1.5, seconds: seconds, to: dir.appendingPathComponent("wallpaper"))
        model.wallpaper = false
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: - Recording

    /// Steps the animation clock one frame at a time and captures the window
    /// after each step. `each` runs before every frame with the shot's time
    private static func record(_ w: NSWindow, scale: CGFloat, seconds: Double, to dir: URL,
                               each: ((Double) -> Void)? = nil) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frames = Int(seconds * fps)
        var t = Date().timeIntervalSinceReferenceDate
        AnimationClock.shared.virtual = t
        // let the particles settle onto the virtual clock
        try? await Task.sleep(for: .milliseconds(300))
        for i in 0..<frames {
            each?(Double(i) / fps)
            t += 1 / fps
            AnimationClock.shared.virtual = t
            // a few display refreshes so the views redraw at the new time
            try? await Task.sleep(for: .milliseconds(50))
            guard let rep = capture(w, scale: scale) else { continue }
            let url = dir.appendingPathComponent(String(format: "%04d.jpg", i + 1))
            pending.enter()
            writer.async {
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    try? data.write(to: url)
                }
                pending.leave()
            }
        }
        AnimationClock.shared.virtual = nil
    }

    private static func capture(_ w: NSWindow, scale: CGFloat) -> NSBitmapImageRep? {
        guard let view = w.contentView else { return nil }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // MARK: - Helpers

    private static func mainWindow(_ model: AppModel) async -> NSWindow? {
        if !NSApp.windows.contains(where: { $0.title == "Huecast" && $0.canBecomeMain && $0.isVisible }) {
            model.openMainWindow?()
            try? await Task.sleep(for: .seconds(2))
        }
        return NSApp.windows.first { $0.title == "Huecast" && $0.canBecomeMain }
    }

    /// Clicks our own menu bar icon
    private static func toggleStatusItem() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let button = find(NSStatusBarButton.self, in: w.contentView) { button.performClick(nil) }
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    /// The menu bar icon for a sky at 8x, on a dark menu bar
    private static func icon(_ sky: HourSky) -> NSBitmapImageRep? {
        let image = MenuBarIcon.image(sky)
        let scale: CGFloat = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func savePNG(_ rep: NSBitmapImageRep?, to url: URL) {
        try? rep?.representation(using: .png, properties: [:])?.write(to: url)
    }
}
