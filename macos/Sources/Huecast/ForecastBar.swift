import SwiftUI
import HuecastCore

/// The forecast bar: one small sky per hour, its height the temperature.
/// Hover to magnify (Dock style), click or drag to scrub, arrow keys to
/// step, right click for the next days
struct ForecastBar: View {
    var model: AppModel
    var ink: Color
    var inkSoft: Color
    var inkFaint: Color
    /// smaller, for the menu bar widget
    var compact = false

    @State private var hoverX: CGFloat?
    @State private var dragging = false

    private let maxWidth: CGFloat = 560
    private var gap: CGFloat { compact ? 2 : 3 }
    private let padTop: CGFloat = 14
    private let padBottom: CGFloat = 26
    private let lineBottom: CGFloat = 19

    private var active: Bool { hoverX != nil || dragging }

    var body: some View {
        let hours = model.hours
        let skies = hours.map { model.sky(for: $0) }
        VStack(spacing: compact ? 6 : 12) {
            head(skies)
            GeometryReader { g in
                track(skies, width: g.size.width, height: g.size.height)
            }
            .frame(height: compact ? (active ? 96 : 66) : (active ? 130 : 84))
            .frame(maxWidth: maxWidth)
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.bottom, compact ? 6 : 18)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.35), value: active)
        .contextMenu { daysMenu }
    }

    // MARK: - Low · now · high

    private func head(_ skies: [HourSky]) -> some View {
        let range = model.range
        let sel = skies.indices.contains(model.selected) ? skies[model.selected] : nil
        let feels = sel?.hour.feels.map { " · \(model.toUnit($0))°" } ?? ""
        let label = sel.map { ($0.hour.isNow ? "Now" : "\(Format.pad($0.local.hour)):00") + feels } ?? ""
        return HStack(alignment: .firstTextBaseline) {
            Text("Low \(model.toUnit(range.min))°")
                .font(.system(size: 9)).tracking(1.35)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(active ? 0 : 1)
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(ink)
                .scaleEffect(active ? 1.25 : 1)
                .contentTransition(.numericText(countsDown: model.rollDirection < 0))
                .animation(.easeOut(duration: 0.3), value: label)
            Text("High \(model.toUnit(range.max))°")
                .font(.system(size: 9)).tracking(1.35)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(active ? 0 : 1)
        }
        .textCase(.uppercase)
        .monospacedDigit()
        .foregroundStyle(inkSoft)
        .frame(maxWidth: maxWidth)
    }

    // MARK: - Bars

    private struct BarLayout { var x: CGFloat; var width: CGFloat; var mag: CGFloat }

    /// Bars near the pointer grow taller and wider, pushing their
    /// neighbours aside (~2.5 bars either side feel it)
    private func layout(count n: Int, width: CGFloat) -> [BarLayout] {
        guard n > 0 else { return [] }
        let gaps = gap * CGFloat(n - 1)
        var weights = Array(repeating: CGFloat(1), count: n)
        var mags = Array(repeating: CGFloat(1), count: n)
        if let hoverX {
            let pos = hoverX / width * CGFloat(n) - 0.5
            for i in 0..<n {
                let d = CGFloat(i) - pos
                let g = exp(-(d * d) / 12.5)
                weights[i] = 1 + 1.4 * g
                mags[i] = 1 + 0.55 * g
            }
        }
        let unit = (width - gaps) / weights.reduce(0, +)
        var x: CGFloat = 0
        return (0..<n).map { i in
            defer { x += unit * weights[i] + gap }
            return BarLayout(x: x, width: unit * weights[i], mag: mags[i])
        }
    }

    private func track(_ skies: [HourSky], width: CGFloat, height: CGFloat) -> some View {
        let n = skies.count
        let bars = layout(count: n, width: width)
        let temps = skies.map(\.hour.temp)
        let lo = temps.min() ?? 0
        let range = max((temps.max() ?? 0) - lo, 4)
        let barArea = height - padTop - padBottom
        let slot = width / CGFloat(max(n, 1)) // un-magnified, for the night line

        return ZStack(alignment: .topLeading) {
            // night hours: one straight line under the bars, a small moon
            // where each night starts and a sun where it ends
            ForEach(Array(skies.enumerated()), id: \.offset) { i, s in
                if !s.hour.isDay {
                    Rectangle().fill(inkFaint)
                        .frame(width: slot, height: 2)
                        .offset(x: CGFloat(i) * slot, y: height - lineBottom - 2)
                }
                let prevDay = i == 0 ? true : skies[i - 1].hour.isDay
                if !s.hour.isDay && prevDay {
                    Circle().strokeBorder(inkSoft, lineWidth: 1.2).frame(width: 7, height: 7)
                        .offset(x: CGFloat(i) * slot - 9, y: height - lineBottom - 4.5)
                }
                if s.hour.isDay && i > 0 && !prevDay {
                    Circle().fill(inkSoft).frame(width: 7, height: 7)
                        .offset(x: CGFloat(i) * slot + 2, y: height - lineBottom - 4.5)
                }
            }

            ForEach(Array(skies.enumerated()), id: \.offset) { i, s in
                let b = bars[i]
                let selected = i == model.selected
                let scale = b.mag * (selected ? 1.1 : 1)
                let frac = CGFloat(0.18 + (s.hour.temp - lo) / range * 0.82)
                let h = max(4, barArea * frac) * scale
                let bottom = height - padBottom
                bar(s, selected: selected)
                    .frame(width: b.width, height: h)
                    .offset(x: b.x, y: bottom - h)
                marks(s.condition.levels)
                    .frame(width: b.width, height: 20, alignment: .bottom)
                    .offset(x: b.x, y: bottom - h - 4 - 20)
                if i > 0, let hour = s.local.hour, hour % 6 == 0 {
                    Text(Format.pad(hour))
                        .font(.system(size: 8)).tracking(0.8)
                        .foregroundStyle(inkSoft)
                        .fixedSize()
                        .frame(width: b.width)
                        .offset(x: b.x, y: bottom + 11)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18), value: hoverX)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: if !dragging { hoverX = nil }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    hoverX = v.location.x
                    model.select(index(at: v.location.x, bars: layout(count: n, width: width)))
                }
                .onEnded { _ in dragging = false }
        )
    }

    /// The bar under the pointer, using the magnified bar positions
    private func index(at x: CGFloat, bars: [BarLayout]) -> Int {
        bars.firstIndex { x < $0.x + $0.width + gap / 2 } ?? max(bars.count - 1, 0)
    }

    /// Each bar is that hour's sky: time colour at the bottom, temperature on top
    private func bar(_ s: HourSky, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return shape
            .fill(LinearGradient(stops: oklchStops(s.timeColor, s.tempColor, count: 5), startPoint: .bottom, endPoint: .top))
            .overlay(shape.strokeBorder(.white.opacity(selected ? 0.4 : 0.22), lineWidth: 1))
            .overlay(shape.stroke(ink, lineWidth: selected ? 1.5 : 0).padding(-1.5))
    }

    /// Precipitation: rain ticks or snow dots, more for heavier
    @ViewBuilder
    private func marks(_ levels: Levels) -> some View {
        if let m = Conditions.marks(levels) {
            if m.snow {
                VStack(spacing: 2) {
                    ForEach(0..<m.count, id: \.self) { _ in Circle().fill(inkSoft).frame(width: 3, height: 3) }
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<m.count, id: \.self) { _ in Rectangle().fill(inkSoft).frame(width: 1, height: 6) }
                }
            }
        }
    }

    // MARK: - Next days

    @ViewBuilder
    private var daysMenu: some View {
        if model.forecast?.days.isEmpty == false {
            Button("Next Days…") { model.showDays = true }
            if model.viewDay != nil {
                Button("Back to the Next 24 Hours") { model.showDay(nil) }
            }
        }
    }
}
