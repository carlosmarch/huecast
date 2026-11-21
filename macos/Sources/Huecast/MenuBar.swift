import SwiftUI
import AppKit
import HuecastCore

// MARK: - Icon

/// The menu bar icon: a full circle painted with the current sky (time of
/// day -> temperature) and a border in the menu bar's text colour, so it
/// reads on light and dark menu bars and over any wallpaper
enum MenuBarIcon {
    static func image(_ sky: HourSky?, size: CGFloat = 16) -> NSImage {
        let time = sky?.timeColor, temp = sky?.tempColor
        let image = NSImage(size: NSSize(width: size + 2, height: size + 2), flipped: false) { rect in
            let border: CGFloat = 1.25
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1 + border / 2, dy: 1 + border / 2))
            if let time, let temp {
                let steps = (0..<5).map { Palette.mix(time, temp, Double($0) / 4) }
                let gradient = NSGradient(colors: steps.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) })
                // the sky's -65deg CSS angle, in AppKit's y-up degrees
                gradient?.draw(in: circle, angle: 155)
            }
            // labelColor follows the menu bar's appearance at draw time
            NSColor.labelColor.withAlphaComponent(sky == nil ? 0.5 : 0.85).setStroke()
            circle.lineWidth = border
            circle.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = sky.map { "Huecast, \($0.condition.label)" } ?? "Huecast"
        return image
    }
}

struct MenuBarLabel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // "now", whatever hour the window is scrubbed to
        let now = model.forecast.flatMap { $0.next.first }.map { model.sky(for: $0) }
        let ready = model.status == .ready ? now : nil
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(ready))
            if model.menuBarTemperature, let ready {
                Text("\(model.toUnit(ready.hour.temp))°").monospacedDigit()
            }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            model.start()
        }
    }
}

// MARK: - Widget

/// What opens from the menu bar icon: a small sky like a widget with the
/// temperature, the condition and the sun. Click it to open Huecast full
/// screen (or, while it's the desktop wallpaper, to bring the window back);
/// right click for options
struct MenuBarWidget: View {
    var model: AppModel

    @Environment(\.openWindow) private var openWindow
    @State private var sunFrame: CGRect = .zero
    @State private var panel: NSWindow?

    static let size = CGSize(width: 248, height: 96)

    var body: some View {
        let cur = model.status == .ready ? model.current : nil
        let ink = Ink(dark: cur?.inkDark ?? false)

        ZStack {
            SkyView(paint: cur.map { SkyPaint(time: $0.timeColor, temp: $0.tempColor) },
                    darken: cur?.condition.fx.darken ?? 0)
            SceneView(state: sceneState(cur), anchor: sunFrame.minY...max(sunFrame.maxY, sunFrame.minY))
                .blendMode(ink.dark ? .exclusion : .normal)
            content(cur, ink: ink)
        }
        .coordinateSpace(name: "widget")
        .foregroundStyle(ink.main)
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .contentShape(Rectangle())
        // click for more: Huecast full screen
        .onTapGesture(perform: openFullScreen)
        .help("Open Huecast")
        .contextMenu {
            Toggle("Temperature in Menu Bar", isOn: Binding(get: { model.menuBarTemperature },
                                                             set: { model.menuBarTemperature = $0 }))
            Toggle("Show in Dock", isOn: Binding(get: { model.showInDock }, set: { model.showInDock = $0 }))
            Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
            Divider()
            Button("Open Huecast") { openFullScreen() }
            Button(model.wallpaper ? "Leave Desktop Wallpaper" : "Use as Desktop Wallpaper") { model.wallpaper.toggle() }
            Divider()
            Picker("Units", selection: Binding(get: { model.unit }, set: { model.unit = $0 })) {
                Text("°C").tag(TempUnit.c)
                Text("°F").tag(TempUnit.f)
            }
            Divider()
            Button("Quit Huecast") { NSApp.terminate(nil) }
        }
        .onAppear {
            model.start()
            closeMainWindow()
        }
        // the panel is kept between opens, so onAppear can fire just once
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = note.object as? NSWindow, w === panel { closeMainWindow() }
        }
        .background(WindowFinder { w in if panel !== w { DispatchQueue.main.async { panel = w } } })
    }

    /// Just the temperature, the condition and the sun or moon
    private func content(_ cur: HourSky?, ink: Ink) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                temperature(cur, size: 30, ink: ink)
                Text(headline(cur))
                    .font(.system(size: 9, weight: .medium)).tracking(1.8)
                    .foregroundStyle(ink.soft)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            sun(cur, ink: ink, size: 44)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Pieces

    /// One or the other: the widget opens instead of the window (but leaves
    /// the window alone while it's the desktop wallpaper)
    private func closeMainWindow() {
        guard !model.wallpaper else { return }
        NSApp.windows.first { $0.title == "Huecast" && $0.canBecomeMain && $0.isVisible }?.close()
    }

    /// Closes the widget and opens the Huecast window full screen
    private func openFullScreen() {
        panel?.orderOut(nil)
        // the wallpaper can't be clicked: the widget brings the window back
        if model.wallpaper {
            model.wallpaper = false
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        model.select(0)
        // the window may still be on its way
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let main = NSApp.windows.first(where: { $0.title == "Huecast" && $0.canBecomeMain }) else { return }
            main.makeKeyAndOrderFront(nil)
            if !main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
        }
    }

    private func headline(_ cur: HourSky?) -> String {
        switch model.status {
        case .locating: return "LOCATING"
        case .loading: return "LOADING"
        case let .failed(message, _): return message.uppercased()
        case .ready: return (cur?.condition.label ?? "").uppercased()
        }
    }

    private func temperature(_ cur: HourSky?, size: CGFloat, ink: Ink) -> some View {
        HStack(alignment: .top, spacing: 1) {
            Text(cur.map { "\(model.toUnit($0.hour.temp))" } ?? "–")
                .font(.system(size: size, weight: .thin))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: model.rollDirection < 0))
            Text("°").font(.system(size: size / 2, weight: .thin)).padding(.top, 1)
            Text(model.unit.rawValue)
                .font(.system(size: size * 0.3, weight: .regular)).tracking(1.2)
                .foregroundStyle(ink.soft)
                .padding(.top, size * 0.12)
        }
        .animation(.easeOut(duration: 0.3), value: cur?.hour.temp)
    }

    private func sun(_ cur: HourSky?, ink: Ink, size: CGFloat) -> some View {
        SunView(state: sunState(cur, ink: ink), size: size)
            .background(GeometryReader { g in
                Color.clear.preference(key: SunFrameKey.self, value: g.frame(in: .named("widget")))
            })
            .onPreferenceChange(SunFrameKey.self) { sunFrame = $0 }
    }

    private func sunState(_ cur: HourSky?, ink: Ink) -> SunState {
        switch model.status {
        case .locating, .loading: return SunState(kind: .loading)
        case .failed: return SunState(kind: .empty)
        case .ready: break
        }
        guard let cur else { return SunState(kind: .loading) }
        let fx = cur.condition.fx
        let halo = (Conditions.iceHalo(temp: cur.hour.temp, levels: cur.condition.levels) * 10).rounded() / 10
        if !cur.hour.isDay { return SunState(kind: .moon, halo: halo) }
        return SunState(kind: .sun, veiled: fx.veil, intensity: fx.veil ? .none : Sky.sunIntensity(cur.hour.temp),
                        halo: halo, edge: ink.dark)
    }

    private func sceneState(_ cur: HourSky?) -> SceneState? {
        guard let cur else { return nil }
        let stars = cur.hour.isDay ? 0 : (Sky.stars(hour: cur.skyHour) == 0 ? 40 : Sky.stars(hour: cur.skyHour))
        return SceneState(fx: cur.condition.fx, stars: cur.condition.fx.clouds > 10 ? stars / 4 : stars,
                          timeColor: cur.timeColor)
    }
}

struct WidgetButton: View {
    var symbol: String
    var help: String
    var ink: Ink
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(ink.main.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(ink.main.opacity(0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
