import AppKit
import HuecastCore

/// Marketing pictures for the screenshot mode: Huecast on a Mac desktop.
/// A soft gradient in Huecast's own colours, a menu bar with the Huecast
/// icon, a Dock with Finder, Photos and Huecast, and either the window
/// floating in the middle or the menu bar widget open. 1440x900 at 2x
@MainActor
enum Marketing {
    static let size = CGSize(width: 1440, height: 900)
    static let menuBar: CGFloat = 26

    static func render(window: NSImage?, widget: NSImage?, icon: HourSky?, temp: String) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            background()
            let iconFrame = drawMenuBar(icon: icon, temp: temp)
            if let window { drawWindow(window) }
            if let widget { drawWidget(widget, under: iconFrame) }
            drawDock()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Desktop

    private static func color(_ c: RGB, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a)
    }

    /// dusk: deep violet into the warm temperature colours
    private static func background() {
        let rect = NSRect(origin: .zero, size: size)
        let stops: [RGB] = [Tokens.timeDusk, Tokens.timeDawn, Tokens.tempWarm, Tokens.tempHot]
        var colors: [NSColor] = []
        for i in 0..<(stops.count - 1) {
            for k in 0..<6 { colors.append(color(Palette.mix(stops[i], stops[i + 1], Double(k) / 6))) }
        }
        colors.append(color(stops[stops.count - 1]))
        NSGradient(colors: colors)?.draw(in: rect, angle: 115)
        // a soft glow low on the right, like a sun just set
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])
        glow?.draw(fromCenter: NSPoint(x: size.width * 0.78, y: size.height * 0.08), radius: 0,
                   toCenter: NSPoint(x: size.width * 0.78, y: size.height * 0.08), radius: size.width * 0.45, options: [])
    }

    // MARK: - Menu bar

    /// returns where the Huecast icon sits, for the widget
    private static func drawMenuBar(icon: HourSky?, temp: String) -> NSRect {
        let bar = NSRect(x: 0, y: size.height - menuBar, width: size.width, height: menuBar)
        NSColor.black.withAlphaComponent(0.16).setFill()
        bar.fill()

        let midY = bar.midY
        func text(_ s: String, at x: CGFloat, bold: Bool = false, alignRight: Bool = false) -> CGFloat {
            let str = NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: bold ? .bold : .medium),
                .foregroundColor: NSColor.white,
            ])
            let w = str.size().width
            let origin = NSPoint(x: alignRight ? x - w : x, y: midY - str.size().height / 2)
            str.draw(at: origin)
            return w
        }

        var x: CGFloat = 20
        x += text("\u{F8FF}", at: x) + 22
        x += text("Huecast", at: x, bold: true) + 22
        for item in ["Edit", "View", "Weather", "Window", "Help"] { x += text(item, at: x) + 22 }

        // right side: clock, then Huecast's icon and temperature
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM  HH:mm"
        var right = size.width - 18
        right -= text(f.string(from: Date()), at: right, alignRight: true) + 22
        var iconFrame = NSRect.zero
        if !temp.isEmpty { right -= text(temp, at: right, alignRight: true) + 5 }
        let image = MenuBarIcon.image(icon)
        iconFrame = NSRect(x: right - image.size.width, y: midY - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        // the item is "open" when the widget shows: a soft highlight behind it
        image.draw(in: iconFrame)
        return iconFrame
    }

    // MARK: - Window and widget

    private static func shadowed(_ rect: NSRect, radius: CGFloat, blur: CGFloat, alpha: CGFloat, draw: () -> Void) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -blur * 0.35)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        draw()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        rim.lineWidth = 0.5
        rim.stroke()
    }

    private static func drawWindow(_ image: NSImage) {
        // fit the window between the menu bar and the Dock
        let maxW: CGFloat = 1040, maxH: CGFloat = 660
        let k = min(maxW / image.size.width, maxH / image.size.height, 1)
        let w = image.size.width * k, h = image.size.height * k
        let rect = NSRect(x: (size.width - w) / 2, y: 118 + (size.height - menuBar - 118 - h) / 2, width: w, height: h)
        shadowed(rect, radius: 12, blur: 60, alpha: 0.5) {
            image.draw(in: rect)
            // the traffic lights the capture leaves out
            let colors = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                          NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                          NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
            for (i, c) in colors.enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(i) * 20, y: rect.maxY - 14 - 12, width: 12, height: 12)).fill()
            }
        }
    }

    private static func drawWidget(_ image: NSImage, under icon: NSRect) {
        let w = image.size.width, h = image.size.height
        let x = min(max(icon.midX - w / 2, 12), size.width - w - 12)
        let rect = NSRect(x: x, y: size.height - menuBar - 6 - h, width: w, height: h)
        shadowed(rect, radius: 12, blur: 36, alpha: 0.45) { image.draw(in: rect) }
    }

    // MARK: - Dock

    private static func drawDock() {
        let apps: [(NSImage, Bool)] = [
            (NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"), true),
            (NSWorkspace.shared.icon(forFile: "/System/Applications/Photos.app"), false),
            (NSApp.applicationIconImage ?? NSImage(), true),
        ]
        let iconSize: CGFloat = 60, gap: CGFloat = 10, pad: CGFloat = 10
        let width = CGFloat(apps.count) * iconSize + CGFloat(apps.count - 1) * gap + pad * 2
        let dock = NSRect(x: (size.width - width) / 2, y: 10, width: width, height: iconSize + pad * 2)
        let path = NSBezierPath(roundedRect: dock, xRadius: 22, yRadius: 22)
        NSColor.white.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        for (i, (icon, running)) in apps.enumerated() {
            let x = dock.minX + pad + CGFloat(i) * (iconSize + gap)
            icon.draw(in: NSRect(x: x, y: dock.minY + pad, width: iconSize, height: iconSize))
            if running {
                NSColor.white.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + iconSize / 2 - 2, y: dock.minY + 3, width: 4, height: 4)).fill()
            }
        }
    }
}
