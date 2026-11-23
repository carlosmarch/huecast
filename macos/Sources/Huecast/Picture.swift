import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HuecastCore

/// Save as picture: the sky, its weather, the sun or moon and the words,
/// drawn into a 2880x1800 PNG
@MainActor
enum Picture {
    static func save(model: AppModel) {
        guard let cur = model.current, let place = model.place else { return }
        let size = CGSize(width: 1440, height: 900)
        let renderer = ImageRenderer(content: PictureView(sky: cur, place: place.label, unit: model.unit,
                                                          temp: model.toUnit(cur.hour.temp))
            .frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            model.showToast("Couldn't draw the picture")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let name = place.label.split(separator: ",").first.map(String.init) ?? "Huecast"
        panel.nameFieldStringValue = "Huecast \(name) \(Format.pad(cur.local.hour))h.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                Task { @MainActor in Analytics.track("save_picture", ["method": "save_panel"]) }
            } catch {
                Task { @MainActor in model.showToast("Couldn't save the picture") }
            }
        }
    }
}

private struct PictureView: View {
    var sky: HourSky
    var place: String
    var unit: TempUnit
    var temp: Int

    var body: some View {
        let ink = Ink(dark: sky.inkDark)
        let fx = sky.condition.fx
        let engine = SceneEngine()
        let stars = sky.hour.isDay ? 0 : (Sky.stars(hour: sky.skyHour) == 0 ? 40 : Sky.stars(hour: sky.skyHour))
        engine.anchor = 318...422
        engine.set(SceneState(fx: fx, stars: fx.clouds > 10 ? stars / 4 : stars, timeColor: sky.timeColor), instant: true)

        let halo = Conditions.iceHalo(temp: sky.hour.temp, levels: sky.condition.levels)
        let sun = sky.hour.isDay
            ? SunState(kind: .sun, veiled: fx.veil, intensity: fx.veil ? .none : Sky.sunIntensity(sky.hour.temp), halo: halo, edge: ink.dark)
            : SunState(kind: .moon, halo: halo)

        return ZStack {
            CSSGradient(from: sky.timeColor, to: sky.tempColor)
            Color(Tokens.veil).opacity(fx.darken)
            Canvas { ctx, size in engine.draw(ctx, size: size, time: 1, still: true) }
                .blendMode(ink.dark ? .exclusion : .normal)
            VStack(spacing: 0) {
                Text(sky.condition.label.uppercased())
                    .font(.system(size: 16, weight: .bold)).tracking(4)
                    .padding(.bottom, 44)
                SunView(state: sun)
                HStack(alignment: .top, spacing: 2) {
                    Text("\(temp)").font(.system(size: 56, weight: .light))
                    Text("°").font(.system(size: 28, weight: .light)).padding(.top, 2)
                    Text(unit.rawValue).font(.system(size: 13, weight: .semibold)).tracking(2)
                        .foregroundStyle(ink.soft).padding(.top, 6)
                }
                .padding(.top, 40)
                VStack(spacing: 6) {
                    Text(place)
                    Text("\(Format.date(sky.local)) · \(Format.pad(sky.local.hour)):\(Format.pad(sky.local.minute))")
                        .foregroundStyle(ink.soft)
                }
                .font(.system(size: 12)).tracking(2).textCase(.uppercase)
                .padding(.top, 14)
            }
            .foregroundStyle(ink.main)
        }
    }
}
