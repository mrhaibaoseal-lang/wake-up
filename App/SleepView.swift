import SwiftUI
import Charts

/// 「睡眠」分頁：本週時數、每天長條圖、起床速度。資料只在 App 裡，不放小工具。
struct SleepView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [NightRecord] = []

    private var stats: SleepStats { SleepStats(records: records) }

    var body: some View {
        let stats = stats
        ScrollView {
            VStack(spacing: 16) {
                header
                summaryCard(stats)
                chartCard(stats)
                wakeCard(stats)
                Text("時數 = 上膛到掃碼，上膛後還在滑手機的時間也會算進去。少於 1 小時或超過 16 小時的不計入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .refreshable { load() }
        .onAppear(perform: load)
        .onChange(of: model.state.phase) { _, _ in load() }
    }

    private func load() {
        records = SleepStore.load()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("睡眠").font(.system(size: 34, weight: .bold))
                Text("本週（週一開始）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func summaryCard(_ stats: SleepStats) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("本週總時數").font(.subheadline).foregroundStyle(.secondary)
                Text(stats.totalHours > 0 ? SleepStats.hoursText(stats.totalHours) : "—")
                    .font(.title2.bold())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("每晚平均").font(.subheadline).foregroundStyle(.secondary)
                Text(stats.averageHours.map(SleepStats.hoursText) ?? "—")
                    .font(.title2.bold())
                    .foregroundStyle(Color.wakeAccent)
            }
        }
        .card()
    }

    private func chartCard(_ stats: SleepStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每天睡幾小時").font(.headline)
            Chart(stats.days) { day in
                BarMark(
                    x: .value("星期", day.label),
                    y: .value("小時", day.hours ?? 0)
                )
                .foregroundStyle(Color.wakeAccent.gradient)
                .cornerRadius(6)
                .annotation(position: .top) {
                    if let hours = day.hours {
                        Text(String(format: "%.1f", hours))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartYScale(domain: 0...max(10, (stats.days.compactMap(\.hours).max() ?? 0) + 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 4, 8, 12]) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
        }
        .card()
    }

    private func wakeCard(_ stats: SleepStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("起床速度").font(.headline)
                Spacer()
                Text("連續 \(stats.fastStreak) 天")
                    .font(.title3.bold())
                    .foregroundStyle(stats.fastStreak > 0 ? Color.wakeAccent : .secondary)
            }
            Text("響鈴到掃碼花幾分鐘；連續天數只算 \(Int(SleepStats.fastLimit)) 分鐘內掃碼的日子")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(stats.days) { day in
                HStack {
                    Text("週\(day.label)")
                        .frame(width: 40, alignment: .leading)
                    if let minutes = day.wakeMinutes {
                        let fast = minutes <= SleepStats.fastLimit
                        Image(systemName: fast ? "bolt.fill" : "tortoise.fill")
                            .foregroundStyle(fast ? Color.wakeAccent : .secondary)
                            .frame(width: 22)
                        Text("\(Int(minutes.rounded())) 分鐘")
                        Spacer()
                        if day.rearmCount > 0 {
                            Text("被關 \(day.rearmCount) 次")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 3)
            }
        }
        .card()
    }
}
