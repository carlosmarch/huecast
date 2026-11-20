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
        .onAppear { model.start() }
    }
}

// MARK: - Widget

/// What opens from the menu bar icon: a small sky like a widget, which
/// expands to show the forecast bar
struct MenuBarWidget: View {
    var model: AppModel

    @Environment(\.openWindow) private var openWindow
    @State private var sunFrame: CGRect = .zero
    @State private var window: NSWindow?

    static let compact = CGSize(width: 320, height: 172)
    static let expanded = CGSize(width: 380, height: 500)

    var body: some View {
        let expanded = model.widgetExpanded
        let size = expanded ? Self.expanded : Self.compact
        let cur = model.status == .ready ? model.current : nil
        let ink = Ink(dark: cur?.inkDark ?? false)

        ZStack {
            SkyView(paint: cur.map { SkyPaint(time: $0.timeColor, temp: $0.tempColor) },
                    darken: cur?.condition.fx.darken ?? 0)
            SceneView(state: sceneState(cur), anchor: sunFrame.minY...max(sunFrame.maxY, sunFrame.minY))
                .blendMode(ink.dark ? .exclusion : .normal)
            if expanded {
                expandedContent(cur, ink: ink)
            } else {
                compactContent(cur, ink: ink)
            }
        }
        .coordinateSpace(name: "widget")
        .foregroundStyle(ink.main)
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.4), value: expanded)
        .onAppear { model.start() }
        .background(WindowFinder { w in if window !== w { DispatchQueue.main.async { window = w } } })
        .onChange(of: expanded) { _, new in fit(window, to: new ? Self.expanded : Self.compact) }
    }

    // MARK: Compact: place, condition, temperature and the sun

    private func compactContent(_ cur: HourSky?, ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow(cur, ink: ink)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    temperature(cur, size: 44, ink: ink)
                    Text(headline(cur))
                        .font(.system(size: 11, weight: .bold)).tracking(2.2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                sun(cur, ink: ink, size: 58)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
        .padding(16)
    }

    // MARK: Expanded: the big screen in small, with the forecast bar

    private func expandedContent(_ cur: HourSky?, ink: Ink) -> some View {
        VStack(spacing: 0) {
            topRow(cur, ink: ink)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            Spacer(minLength: 0)
            Text(headline(cur))
                .font(.system(size: 13, weight: .bold)).tracking(3.2)
                .padding(.bottom, 26)
            sun(cur, ink: ink, size: 84)
            temperature(cur, size: 46, ink: ink)
                .padding(.top, 22)
            Text(cur.map { Format.date($0.local) } ?? " ")
                .font(.system(size: 10)).tracking(1.6).textCase(.uppercase)
                .foregroundStyle(ink.soft)
                .contentTransition(.numericText(countsDown: model.rollDirection < 0))
                .padding(.top, 8)
            Spacer(minLength: 0)
            if cur != nil {
                ForecastBar(model: model, ink: ink.main, inkSoft: ink.soft, inkFaint: ink.faint, compact: true)
            }
            bottomRow(ink: ink)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }

    private func topRow(_ cur: HourSky?, ink: Ink) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.place?.label ?? "Huecast")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                if !model.widgetExpanded {
                    Text(cur.map { $0.hour.isNow ? "Now" : "\(Format.pad($0.local.hour)):00" } ?? " ")
                        .font(.system(size: 10)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(ink.soft)
                }
            }
            Spacer()
            WidgetButton(symbol: model.widgetExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: model.widgetExpanded ? "Collapse" : "Expand", ink: ink) {
                model.widgetExpanded.toggle()
            }
        }
    }

    private func bottomRow(ink: Ink) -> some View {
        HStack(spacing: 8) {
            WidgetButton(symbol: "location", help: "Use my location", ink: ink) { model.locate() }
            WidgetButton(symbol: "dice", help: "Random city", ink: ink) { model.openRandomCity() }
            Spacer()
            Button(action: openApp) {
                Text("Open Huecast")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(ink.main.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(ink.main.opacity(0.2), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Menu {
                Toggle("Temperature in Menu Bar", isOn: Binding(get: { model.menuBarTemperature },
                                                                 set: { model.menuBarTemperature = $0 }))
                Picker("Units", selection: Binding(get: { model.unit }, set: { model.unit = $0 })) {
                    Text("°C").tag(TempUnit.c)
                    Text("°F").tag(TempUnit.f)
                }
                Divider()
                Button("Quit Huecast") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(ink.main.opacity(0.12), in: Circle())
        }
    }

    // MARK: Pieces

    /// The menu bar window grows with its content but never shrinks back:
    /// resize it by hand, keeping its top edge under the menu bar
    private func fit(_ window: NSWindow?, to size: CGSize) {
        guard let window else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: true)
    }

    private func openApp() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
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
                .font(.system(size: size, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: model.rollDirection < 0))
            Text("°").font(.system(size: size / 2, weight: .light)).padding(.top, 1)
            Text(model.unit.rawValue)
                .font(.system(size: size * 0.24, weight: .semibold)).tracking(1.5)
                .foregroundStyle(ink.soft)
                .padding(.top, size * 0.12)
        }
        .animation(.easeOut(duration: 0.3), value: cur?.hour.temp)
        .onTapGesture { model.toggleUnit() }
        .help("Switch between Celsius and Fahrenheit")
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
