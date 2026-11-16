import SwiftUI
import WidgetKit
import ActivityKit
import AlarmKit

@main
struct WakeWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        AlarmLiveActivity()
    }
}

// MARK: - 桌面 / 鎖屏小工具：顯示 App Group 共用的即時狀態

struct StatusEntry: TimelineEntry {
    let date: Date
    let state: PoCState
    let group: String
    let lastLog: String
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), state: PoCState(), group: "—", lastLog: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .after(Date().addingTimeInterval(900))))
    }

    private func makeEntry() -> StatusEntry {
        StatusEntry(
            date: Date(),
            state: Store.load(),
            group: AppGroup.resolved?.id ?? "❌ 無 App Group",
            lastLog: Log.lastLine()
        )
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("起床・\(entry.state.phase.title)").font(.headline).lineLimit(1)
            Text("重排 \(entry.state.rearmCount) 次").font(.caption)
            Text(entry.group).font(.caption2).lineLimit(1)
            if family != .accessoryRectangular {
                Text(entry.lastLog).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WakeStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("起床狀態")
        .description("顯示鬧鐘階段與 App Group 測試結果")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - AlarmKit 的 Live Activity（鎖屏 / 動態島）

struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeMetadata>.self) { _ in
            HStack {
                Image(systemName: "alarm.fill")
                Text("起床鬧鐘").font(.headline)
                Spacer()
                Text("去浴室掃碼").font(.caption)
            }
            .padding()
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("起床！去浴室掃碼")
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
            } compactTrailing: {
                Text("起床")
            } minimal: {
                Image(systemName: "alarm.fill")
            }
        }
    }
}
