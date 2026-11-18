import SwiftUI

/// 起床後的天氣卡：現在溫度、今天範圍、穿什麼、要不要帶傘
struct WeatherCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今天天氣").font(.headline)
                Spacer()
                if model.weatherLoading {
                    ProgressView()
                } else if let report = model.weather {
                    Text("更新於 \(report.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(report.fetchedAt.timeIntervalSinceNow < -3 * 3600 ? .orange : .secondary)
                }
            }

            if let report = model.weather {
                content(report)
            } else if !model.weatherLoading {
                Text("還沒有天氣資料，下拉重新整理試試看。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = model.weatherError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    @ViewBuilder
    private func content(_ report: WeatherReport) -> some View {
        let now = WeatherCode.describe(report.currentCode)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: now.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(deg(report.currentTemp))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("體感 \(deg(report.currentFeels)) · \(now.text)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if let advice = WeatherAdvice.make(report: report, untilHour: model.state.weatherUntilHour,
                                           tolerance: model.state.heatTolerance) {
            Text("\(advice.untilText)：\(deg(advice.tempLow)) ～ \(deg(advice.tempHigh))（體感 \(deg(advice.feelsLow)) ～ \(deg(advice.feelsHigh))）")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            row(icon: "tshirt.fill", tint: .wakeAccent, text: advice.clothing)
            switch advice.umbrella {
            case .needed:
                row(icon: "umbrella.fill", tint: .cyan,
                    text: "要帶傘（降雨機率 \(advice.maxRainChance)%\(advice.rainHours.map { "，\($0)" } ?? "")）")
            case .folding:
                row(icon: "umbrella", tint: .cyan,
                    text: "折疊傘放包包（降雨機率 \(advice.maxRainChance)%\(advice.rainHours.map { "，\($0)" } ?? "")）")
            case .none:
                row(icon: "sun.max", tint: .yellow, text: "不用帶傘（降雨機率 \(advice.maxRainChance)%）")
            }
            ForEach(advice.notes, id: \.self) { note in
                row(icon: "exclamationmark.circle", tint: .orange, text: note)
            }
        }
    }

    private func row(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            Text(text).font(.body.weight(.medium))
        }
    }

    private func deg(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}
