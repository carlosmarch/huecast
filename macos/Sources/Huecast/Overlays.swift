import SwiftUI
import HuecastCore

/// A blurred panel over the sky, closed with Esc or a click outside
struct GlassPanel<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            content
                .padding(18)
                .frame(maxWidth: 560)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.16)))
                .padding(.horizontal, 24)
                .padding(.top, 64)
                .padding(.bottom, 24)
        }
        .environment(\.colorScheme, .dark)
        .background {
            // Esc closes
            Button("Close", action: onClose).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
    }
}

// MARK: - Search

struct SearchPanel: View {
    var model: AppModel
    @State private var query = ""
    @State private var results: [SearchResult]?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        GlassPanel(onClose: close) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search city", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { if let first = results?.first { pick(first.place) } }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { list }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = nil; failed = false; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let r = try await WeatherAPI.search(q)
                if !Task.isCancelled { results = r; failed = false }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let results {
            if results.isEmpty {
                note("No places found")
            }
            ForEach(results) { r in
                row(icon: "mappin", title: r.name, subtitle: r.region) { pick(r.place, from: "search") }
            }
        } else if failed {
            note("Search is unavailable right now")
        } else {
            row(icon: "location", title: "Use my location", subtitle: nil) {
                close()
                model.locate()
            }
            row(icon: "dice", title: "Random city", subtitle: "⌘R") {
                close()
                model.openRandomCity()
            }
            if !model.pins.isEmpty {
                note("Pinned")
                ForEach(model.pins) { p in
                    row(icon: "pin", title: p.label, subtitle: nil) { pick(p, from: "pin") }
                        .contextMenu {
                            Button("Unpin") {
                                model.pins.removeAll { $0.isSame(as: p) }
                                Analytics.track("unpin", ["from": "search"])
                            }
                        }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(1.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
    }

    private func row(icon: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func pick(_ place: Place, from: String) {
        Analytics.track("select_place", ["from": from])
        close()
        model.open(place)
    }

    private func close() { model.showSearch = false }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct HoverRow<Label: View>: View {
        var label: Label
        var pressed: Bool
        @State private var hovering = false

        var body: some View {
            label
                .background(.white.opacity(pressed ? 0.17 : hovering ? 0.12 : 0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Next days

/// One small timeline per day; picking one puts its 24 hours on the timeline
struct DaysPanel: View {
    var model: AppModel

    private struct Row: Identifiable {
        var time: Double?
        var name: String
        var note: String
        var hours: [Hour]
        var min: Double
        var max: Double
        var id: String { time.map { "\($0)" } ?? "next" }
    }

    var body: some View {
        GlassPanel(onClose: { model.showDays = false }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT DAYS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                let rows = self.rows
                let temps = rows.flatMap { $0.hours.map(\.temp) }
                let lo = temps.min() ?? 0
                let range = Swift.max((temps.max() ?? 0) - lo, 4)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows) { r in
                            Button {
                                model.showDays = false
                                model.showDay(r.time)
                            } label: {
                                row(r, lo: lo, range: range)
                            }
                            .buttonStyle(RowButtonStyle())
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white, lineWidth: r.time == model.viewDay ? 1.5 : 0)
                            )
                        }
                    }
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [Row] {
        guard let f = model.forecast, let now = f.next.first else { return [] }
        let first = Row(time: nil, name: "Next 24 hours",
                        note: Conditions.condition(code: now.code, wind: now.wind, data: now.data).label.capitalizedFirst,
                        hours: f.next, min: f.next.map(\.temp).min() ?? 0, max: f.next.map(\.temp).max() ?? 0)
        let days = f.days.enumerated().map { i, d -> Row in
            let local = AppModel.utc.dateComponents([.weekday, .day, .month], from: Date(timeIntervalSince1970: d.time + f.offset))
            let date = "\(local.day ?? 1) \(Format.month(local.month))"
            let cond = d.code.map { Conditions.label($0) } ?? ""
            let temps = d.hours.map(\.temp)
            return Row(time: d.time,
                       name: i == 0 ? "Tomorrow" : Format.weekday(local.weekday),
                       note: [date, cond].filter { !$0.isEmpty }.joined(separator: " · ").capitalizedFirst,
                       hours: d.hours,
                       min: d.min ?? temps.min() ?? 0,
                       max: d.max ?? temps.max() ?? 0)
        }
        return [first] + days
    }

    private func row(_ r: Row, lo: Double, range: Double) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 14, weight: .semibold))
                Text(r.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(r.hours.enumerated()), id: \.offset) { _, h in
                    let s = model.sky(for: h)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LinearGradient(colors: [Color(s.timeColor), Color(s.tempColor)], startPoint: .bottom, endPoint: .top))
                        .frame(height: CGFloat(Swift.max(3, 34 * (0.18 + (h.temp - lo) / range * 0.82))))
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack(spacing: 4) {
                Text("\(model.toUnit(r.min))°").foregroundStyle(.secondary)
                Text("\(model.toUnit(r.max))°").fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
