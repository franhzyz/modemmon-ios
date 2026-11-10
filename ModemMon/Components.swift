import SwiftUI
import Charts

// MARK: - Карточка

struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Плитка метрики (StatTile)

struct StatTile: View {
    var title: String
    var value: String
    var sub: String? = nil
    var tone: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Бейдж

enum BadgeTone { case ok, warn, bad, neutral, info }

struct MmBadge: View {
    var text: String
    var tone: BadgeTone = .neutral

    var color: Color {
        switch tone {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .info: return .blue
        case .neutral: return .gray
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Спарклайн (Sparkline)

struct Sparkline: View {
    var values: [Double]
    var color: Color = .blue
    var height: CGFloat = 44

    private struct P: Identifiable {
        let i: Int
        let v: Double
        var id: Int { i }
    }

    var body: some View {
        Chart(values.enumerated().map { P(i: $0.offset, v: $0.element) }) { item in
            LineMark(x: .value("i", item.i), y: .value("v", item.v))
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            AreaMark(x: .value("i", item.i), y: .value("v", item.v))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Прогресс-строка (ProgressRow / QualityBar)

struct ProgressRow: View {
    var label: String
    var value: Double        // 0...1
    var caption: String? = nil
    var color: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - Строка ключ-значение

struct KVRow: View {
    var key: String
    var value: String
    var mono: Bool = false
    var valueTone: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(valueTone)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Сигнальные полоски (SignalBars)

struct SignalBars: View {
    var rsrp: Double?      // -140...-60
    var size: CGFloat = 16

    private var level: Int {
        guard let r = rsrp else { return 0 }
        if r >= -80 { return 4 }
        if r >= -90 { return 3 }
        if r >= -100 { return 2 }
        if r >= -110 { return 1 }
        return 0
    }

    private var tone: Color {
        switch level {
        case 4: return .green
        case 3: return .green
        case 2: return .orange
        case 1: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < level ? tone : Color.primary.opacity(0.15))
                    .frame(width: size * 0.2, height: size * (0.35 + 0.22 * Double(i)))
            }
        }
        .frame(height: size)
    }
}

// MARK: - Цвет RS/SINR

func rsrpColor(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    if v >= -85 { return .green }
    if v >= -95 { return .blue }
    if v >= -105 { return .orange }
    return .red
}

func sinrColor(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    if v >= 20 { return .green }
    if v >= 10 { return .blue }
    if v >= 3 { return .orange }
    return .red
}

// MARK: - Форматтеры

enum Fmt {
    static func bytes(_ b: Int64?) -> String {
        guard let b else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .binary
        return f.string(fromByteCount: b)
    }

    static func kbps(_ k: Double?) -> String {
        guard let k, k.isFinite, k >= 0 else { return "—" }
        if k >= 1_000_000 { return String(format: "%.1f Гбит/с", k / 1_000_000) }
        if k >= 1000 { return String(format: "%.1f Мбит/с", k / 1000) }
        return String(format: "%.0f кбит/с", k)
    }

    static func uptime(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(m) мин" }
        return "\(m) мин"
    }

    static func dbm(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f dBm", v)
    }

    static func db(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f dB", v)
    }

    static func temp(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f °C", v)
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: d)
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(0, s)) с назад" }
        if s < 3600 { return "\(s / 60) мин назад" }
        return "\(s / 3600) ч назад"
    }
}
