import SwiftUI
import HuecastCore

/// Text colours: white, or dark ink on very pale skies
struct Ink {
    var dark: Bool
    var main: Color { dark ? Color(Tokens.inkDark) : .white }
    var soft: Color { dark ? Color(Tokens.inkDark, opacity: 0.72) : .white.opacity(0.7) }
    var faint: Color { dark ? Color(Tokens.inkDark, opacity: 0.25) : .white.opacity(0.28) }
}

struct ContentView: View {
    var model: AppModel
    var desktop: DesktopMode

    @State private var sunFrame: CGRect = .zero
    /// click the sky: the buttons and the low · now · high row slide away
    @State private var clean = false
    @FocusState private var focused: Bool

    var body: some View {
        let cur = model.current
        let ink = Ink(dark: cur?.inkDark ?? false)
        let lum = cur.map { Palette.luminance(Palette.mix($0.timeColor, $0.tempColor)) } ?? 0

        ZStack {
            SkyView(paint: cur.map { SkyPaint(time: $0.timeColor, temp: $0.tempColor) },
                    darken: cur?.condition.fx.darken ?? 0)
                .contentShape(Rectangle())
                .onTapGesture { if !model.wallpaper { withAnimation(.easeOut(duration: 0.35)) { clean.toggle() } } }

            SceneView(state: sceneState(cur), anchor: sunFrame.minY...max(sunFrame.maxY, sunFrame.minY))
                // white over light skies turns dark, like the original drops
                .blendMode(ink.dark ? .exclusion : .normal)

            centre(cur, ink: ink)
                .shadow(color: .black.opacity(lum > 0.3 && lum <= 0.55 ? 0.18 : 0), radius: 7, y: 1)

            if !model.wallpaper {
                toolbar(ink: ink)
                    .opacity(clean ? 0 : 1)
                    .offset(y: clean ? -12 : 0)
                    .allowsHitTesting(!clean)

                if model.status == .ready || model.forecast != nil {
                    VStack {
                        Spacer()
                        ForecastBar(model: model, ink: ink.main, inkSoft: ink.soft, inkFaint: ink.faint)
                            .opacity(model.status == .ready ? 1 : 0.3)
                            .allowsHitTesting(model.status == .ready)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if let toast = model.toast, !model.wallpaper {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if model.showSearch { SearchPanel(model: model).transition(.opacity) }
            if model.showDays { DaysPanel(model: model).transition(.opacity) }
        }
        .coordinateSpace(name: "app")
        .foregroundStyle(ink.main)
        .animation(.easeOut(duration: 0.25), value: model.showSearch)
        .animation(.easeOut(duration: 0.25), value: model.showDays)
        .animation(.easeOut(duration: 0.3), value: model.toast)
        .animation(.easeInOut(duration: 1.2), value: ink.dark)
        .frame(minWidth: 420, minHeight: 560)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress("/") {
            model.showSearch = true
            return .handled
        }
        .onAppear {
            focused = true
            model.start()
        }
        .onChange(of: model.showSearch) { _, open in if !open { focused = true } }
        .onChange(of: model.showDays) { _, open in if !open { focused = true } }
        .onChange(of: model.wallpaper) { _, on in
            desktop.set(on)
            if on { clean = false }
        }
        .background(WindowFinder { desktop.window = $0 })
    }

    private func step(_ d: Int) -> KeyPress.Result {
        guard model.status == .ready, !model.showSearch, !model.showDays else { return .ignored }
        model.select(model.selected + d)
        return .handled
    }

    private func sceneState(_ cur: HourSky?) -> SceneState? {
        guard let cur, model.status == .ready else { return nil }
        let stars = cur.hour.isDay ? 0 : (Sky.stars(hour: cur.skyHour) == 0 ? 40 : Sky.stars(hour: cur.skyHour))
        return SceneState(fx: cur.condition.fx,
                          stars: cur.condition.fx.clouds > 10 ? stars / 4 : stars,
                          timeColor: cur.timeColor)
    }

    // MARK: - Condition, sun, temperature, place

    private func centre(_ cur: HourSky?, ink: Ink) -> some View {
        VStack(spacing: 0) {
            headline(cur, ink: ink)
                .padding(.bottom, 44)
                .opacity(model.wallpaper ? 0 : 1)

            SunView(state: sunState(cur, ink: ink))
                .background(GeometryReader { g in
                    Color.clear.preference(key: SunFrameKey.self, value: g.frame(in: .named("app")))
                })
                .onPreferenceChange(SunFrameKey.self) { sunFrame = $0 }

            Group {
                if model.status == .ready, let cur {
                    Button { model.toggleUnit() } label: { temperature(cur.hour.temp, ink: ink) }
                        .buttonStyle(.plain)
                        .help("Switch between Celsius and Fahrenheit")
                } else if case .failed = model.status {
                    Button("RETRY") { model.retry() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold)).tracking(2.5)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .overlay(Capsule().strokeBorder(ink.faint))
                } else {
                    temperature(0, ink: ink).hidden()
                }
            }
            .padding(.top, 36)
            .opacity(model.wallpaper ? 0 : 1)

            VStack(spacing: 6) {
                Text(model.place?.label ?? " ")
                Group {
                    if case let .failed(_, detail) = model.status {
                        Text(detail).textCase(nil).tracking(0.4).font(.system(size: 10)).textSelection(.enabled)
                    } else if let cur, model.status == .ready {
                        Text(Format.date(cur.local))
                            .contentTransition(.numericText(countsDown: model.rollDirection < 0))
                    } else {
                        Text(" ")
                    }
                }
                .foregroundStyle(ink.soft)
            }
            .font(.system(size: 12))
            .tracking(2)
            .textCase(.uppercase)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.top, 10)
            .opacity(model.wallpaper ? 0 : 1)
        }
        .padding(.top, 72)
        .padding(.bottom, 150)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func headline(_ cur: HourSky?, ink: Ink) -> some View {
        let text: String = {
            switch model.status {
            case .locating: return "Locating"
            case .loading: return "Loading"
            case let .failed(message, _): return message
            case .ready: return cur?.condition.label ?? ""
            }
        }()
        let isStatus = model.status == .locating || model.status == .loading
        Text(text.uppercased())
            .font(.system(size: 16, weight: .bold))
            .tracking(4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .foregroundStyle(isStatus ? ink.soft : ink.main)
            .id(text)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.9), value: text)
    }

    private func temperature(_ celsius: Double, ink: Ink) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text("\(model.toUnit(celsius))")
                .font(.system(size: 56, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: model.rollDirection < 0))
                .animation(.easeOut(duration: 0.35), value: model.toUnit(celsius))
            Text("°").font(.system(size: 28, weight: .light)).padding(.top, 2)
            Text(model.unit.rawValue)
                .font(.system(size: 13, weight: .semibold)).tracking(2)
                .foregroundStyle(ink.soft)
                .padding(.top, 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func sunState(_ cur: HourSky?, ink: Ink) -> SunState {
        switch model.status {
        case .locating, .loading: return SunState(kind: .loading)
        case .failed: return SunState(kind: .empty)
        case .ready: break
        }
        guard let cur else { return SunState(kind: .loading) }
        let h = cur.hour
        let fx = cur.condition.fx
        let halo = (Conditions.iceHalo(temp: h.temp, levels: cur.condition.levels) * 10).rounded() / 10
        if !h.isDay { return SunState(kind: .moon, halo: halo) }
        // a sun behind clouds or fog doesn't shine or pulse
        return SunState(kind: .sun, veiled: fx.veil,
                        intensity: fx.veil ? .none : Sky.sunIntensity(h.temp),
                        halo: halo, edge: ink.dark)
    }

    // MARK: - Toolbar

    private func toolbar(ink: Ink) -> some View {
        VStack {
            HStack(spacing: 10) {
                Spacer()
                ToolButton(symbol: "magnifyingglass", help: "Search city (⌘K)") { model.showSearch = true }
                ToolButton(symbol: "dice", help: "Random city (⌘R)") { model.openRandomCity() }
                Menu {
                    MenuItems(model: model, shortcuts: false)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
            .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .glassCircle()
                .help("Options")
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .foregroundStyle(ink.main.opacity(0.8))
    }
}

struct SunFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct ToolButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .help(help)
    }
}

extension View {
    /// a whisper of glass: the sky lightly blurred behind a faint pane
    func glassCircle() -> some View {
        background(.ultraThinMaterial.opacity(0.35), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// The options, shared by the gear menu and the menu bar (which owns
/// the keyboard shortcuts, so they don't fire twice)
struct MenuItems: View {
    var model: AppModel
    var shortcuts = true

    var body: some View {
        Button("Search City…") { model.showSearch = true }
            .shortcut("k", if: shortcuts)
        Button("Random City") { model.openRandomCity() }
            .shortcut("r", if: shortcuts)
        Button("Use My Location") { model.locate() }
            .shortcut("l", if: shortcuts)
        Button("Next Days…") { model.showDays = true }
            .shortcut("d", if: shortcuts)
            .disabled(model.forecast?.days.isEmpty ?? true)
        Divider()
        Button(model.isPinned ? "Unpin This Place" : "Pin This Place") { model.togglePin() }
            .shortcut("p", if: shortcuts)
            .disabled(model.place == nil || model.status != .ready)
        Button("Save as Picture…") { Picture.save(model: model) }
            .shortcut("s", if: shortcuts)
            .disabled(model.status != .ready)
        Button(model.wallpaper ? "Leave Desktop Wallpaper" : "Use as Desktop Wallpaper") { model.wallpaper.toggle() }
            .shortcut("w", [.command, .shift], if: shortcuts)
        Divider()
        Picker("Units", selection: Binding(get: { model.unit }, set: { model.unit = $0 })) {
            Text("°C").tag(TempUnit.c)
            Text("°F").tag(TempUnit.f)
        }
        Divider()
        Link("How It Works", destination: URL(string: "https://huecast.app/how.html")!)
        Link("About Huecast", destination: URL(string: "https://huecast.app/product/")!)
    }
}

extension View {
    @ViewBuilder
    func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command, if on: Bool) -> some View {
        if on { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}
