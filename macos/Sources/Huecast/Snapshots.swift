import SwiftUI
import AppKit
import HuecastCore

/// Screenshot mode, used by CI: `-snapshots <dir>` (with `-lat -lon -name`).
/// Once the forecast is in, it draws the menu bar icon in several skies,
/// then opens the menu bar widget, expands it and closes it again, writing
/// `<step>.ready` at each step and waiting for `<step>.done` so a script
/// can take a screenshot (`screencapture`). Each window is also saved
/// from inside the app, in case the screen can't be captured
@MainActor
enum Snapshots {
    static let directory: URL? = AppModel.argument("-snapshots").map { URL(fileURLWithPath: $0) }
    private static var ran = false

    static func run(_ model: AppModel) {
        guard let dir = directory, !ran else { return }
        ran = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            if let rep = iconGallery(model), let data = png(rep) {
                try? data.write(to: dir.appendingPathComponent("menubar-icons.png"))
            }
            try? await Task.sleep(for: .seconds(3))
            // the demo starts before the window is up: make sure it's open
            if !NSApp.windows.contains(where: { $0.title == "Huecast" && $0.canBecomeMain && $0.isVisible }) {
                model.openMainWindow?()
                try? await Task.sleep(for: .seconds(2))
            }

            toggleStatusItem()
            try? await Task.sleep(for: .seconds(2.5))
            saveWindows(to: dir, step: "widget")
            let widget = NSApp.windows.first { $0.isVisible && $0.title != "Huecast" && $0.frame.width > 60 && $0.frame.height > 60 }
                .flatMap { capture($0) }
            await step("widget", dir)

            toggleStatusItem()
            try? await Task.sleep(for: .seconds(1.5))
            saveWindows(to: dir, step: "window")
            await step("window", dir)

            // marketing pictures: a roomy window, captured at 2x
            let main = NSApp.windows.first { $0.title == "Huecast" && $0.canBecomeMain }
            if let main {
                main.setFrame(NSRect(x: 0, y: 0, width: 1120, height: 720), display: true)
                try? await Task.sleep(for: .seconds(2))
            }
            let window = main.flatMap { capture($0) }
            let menuIcon = model.forecast?.next.first.map { model.sky(for: $0) }
            let temp = menuIcon.map { "\(model.toUnit($0.hour.temp))°" } ?? ""
            if let window, let data = Marketing.render(window: window, widget: nil, icon: menuIcon, temp: temp) {
                try? data.write(to: dir.appendingPathComponent("marketing-window.png"))
            }
            if let widget, let data = Marketing.render(window: nil, widget: widget, icon: menuIcon, temp: temp) {
                try? data.write(to: dir.appendingPathComponent("marketing-widget.png"))
            }

            if let main = NSApp.windows.first(where: { $0.title == "Huecast" && $0.canBecomeMain }) {
                main.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                saveWindows(to: dir, step: "fullscreen")
                await step("fullscreen", dir)
            }
            NSApp.terminate(nil)
        }
    }

    /// signal a script, then wait (up to 30 s) for it to finish
    private static func step(_ name: String, _ dir: URL) async {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(name).ready").path, contents: nil)
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).done").path) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
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

    private static func saveWindows(to dir: URL, step: String) {
        for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 60 && w.frame.height > 60 {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let kind = w.title == "Huecast" ? "window" : "widget"
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(step)-\(kind)-\(i).png"))
        }
    }

    /// A window's content at 2x, wherever it is on screen
    static func capture(_ w: NSWindow, scale: CGFloat = 2) -> NSImage? {
        guard let view = w.contentView else { return nil }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Icon gallery

    /// The icon in a few skies, on a light and a dark menu bar, at 4x
    private static func iconGallery(_ model: AppModel) -> NSBitmapImageRep? {
        guard let f = model.forecast, let now = f.next.first else { return nil }
        // the same place at other hours and temperatures
        let samples: [(String, Double, Double, Int)] = [
            ("now", 0, now.temp, now.code),
            ("morning 8°", 9, 8, 1),
            ("noon 31°", 13, 31, 0),
            ("dusk 18°", 20, 18, 2),
            ("rain 12°", 15, 12, 63),
            ("night -6°", 2, -6, 0),
        ]
        let midnight = floor((now.time + f.offset) / 86400) * 86400 - f.offset
        let skies: [(String, HourSky)] = samples.map { name, hour, temp, code in
            if name == "now" { return (name, model.sky(for: now)) }
            var h = now
            h.isNow = false
            h.time = midnight + hour * 3600
            h.temp = temp
            h.code = code
            h.isDay = hour >= 7 && hour < 20
            h.data = HourData()
            return (name, model.sky(for: h))
        }

        let scale: CGFloat = 4
        let cell = CGSize(width: 110, height: 24)
        let size = CGSize(width: cell.width * CGFloat(skies.count), height: cell.height * 2 + 16)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let y = size.height - CGFloat(row + 1) * cell.height - CGFloat(row) * 8
                (row == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (i, (label, sky)) in skies.enumerated() {
                    let x = CGFloat(i) * cell.width + 10
                    let icon = MenuBarIcon.image(sky)
                    icon.draw(in: NSRect(x: x, y: y + (cell.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                    let text = NSAttributedString(string: "\(model.toUnit(sky.hour.temp))°  \(label == "now" ? "now" : String(label.split(separator: " ")[0]))", attributes: [
                        .font: NSFont.menuBarFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor,
                    ])
                    text.draw(at: NSPoint(x: x + icon.size.width + 4, y: y + (cell.height - text.size().height) / 2))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func png(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }
}
