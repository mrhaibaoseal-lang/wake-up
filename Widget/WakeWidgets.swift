import SwiftUI
import WidgetKit
import ActivityKit
import AlarmKit
import AppIntents

// 安全底線：小工具、即時動態、控制中心都只能「看」或「打開 App」，
// 不能有停止、解除、延後鬧鐘的按鈕。

@main
struct WakeWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        AlarmLiveActivity()
        WakeControl()
    }
}

// MARK: - 共用樣式

enum WakeStyle {
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.22)
    static let background = Color(red: 0.078, green: 0.078, blue: 0.078) // #141414
    static let ink = Color(red: 0.12, green: 0.05, blue: 0.0)            // 橘底上的深色字
    static let dim = Color.white.opacity(0.55)
    static let openURL = URL(string: "wakeup://open")!

    /// 大字時間固定 24 小時制「07:00」
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Timeline

enum WidgetMode {
    case idle
    case armed(Date?)
    case ringing(Date)
    case awake
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let state: PoCState

    var mode: WidgetMode {
        if state.phase.missionPending {
            guard let alarm = state.alarmDate else { return .armed(nil) }
            return alarm <= date ? .ringing(alarm) : .armed(alarm)
        }
        if state.phase == .verified, let verified = state.verifiedAt,
           Calendar.current.isDate(verified, inSameDayAs: date) {
            return .awake
        }
        return .idle
    }

    var location: String { state.scanLocation.isEmpty ? "客廳" : state.scanLocation }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), state: PoCState())
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), state: Store.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let state = Store.load()
        let now = Date()
        var dates = [now]
        // 到鬧鐘時間自己切成「響鈴中」
        if state.phase.missionPending, let alarm = state.alarmDate, alarm > now {
            dates.append(alarm)
        }
        // 「今天起床了」過了午夜就回到「今晚還沒設鬧鐘」
        if state.phase == .verified,
           let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            dates.append(midnight)
        }
        let entries = dates.map { StatusEntry(date: $0, state: state) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
    }
}

// MARK: - 小工具外觀

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WakeStyle.openURL)
            .containerBackground(for: .widget) { background }
    }

    private var isRinging: Bool {
        if case .ringing = entry.mode { return true }
        return false
    }

    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryCircular: AccessoryWidgetBackground()
        case .accessoryRectangular, .accessoryInline: Color.clear
        default: isRinging ? WakeStyle.accent : WakeStyle.background
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryCircular: CircularView(entry: entry)
        case .accessoryInline: InlineView(entry: entry)
        default: MainBlock(entry: entry)
        }
    }
}

/// 小尺寸本體，也是中尺寸的左半邊
struct MainBlock: View {
    let entry: StatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch entry.mode {
            case .idle:
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(WakeStyle.accent)
                Spacer(minLength: 0)
                Text("今晚還沒設鬧鐘")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("點一下去設定 ›")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WakeStyle.accent)

            case .armed(let alarm):
                Label("已上膛", systemImage: "alarm.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WakeStyle.accent)
                Spacer(minLength: 0)
                if let alarm {
                    Text(WakeStyle.clock.string(from: alarm))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("還有 \(alarm, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(WakeStyle.dim)
                        .lineLimit(1)
                }
                Text("📍\(entry.location)掃碼")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WakeStyle.accent)
                    .lineLimit(1)

            case .ringing(let since):
                Label("響鈴中", systemImage: "alarm.waves.left.and.right.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WakeStyle.ink.opacity(0.8))
                Spacer(minLength: 0)
                Text("去\(entry.location)掃碼")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(WakeStyle.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                Text(since, style: .timer)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(WakeStyle.ink)
                Text("被關 \(entry.state.rearmCount) 次")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WakeStyle.ink.opacity(0.8))

            case .awake:
                Image(systemName: "sun.max.fill")
                    .font(.title2)
                    .foregroundStyle(WakeStyle.accent)
                Spacer(minLength: 0)
                Text("今天起床了")
                    .font(.headline)
                    .foregroundStyle(.white)
                if let verified = entry.state.verifiedAt {
                    Text("\(WakeStyle.clock.string(from: verified)) 掃碼")
                        .font(.caption)
                        .foregroundStyle(WakeStyle.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MediumView: View {
    let entry: StatusEntry

    var body: some View {
        HStack(spacing: 14) {
            MainBlock(entry: entry)
            if case .ringing = entry.mode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("只有\(entry.state.unlockMethod.actionText)才會停")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WakeStyle.ink)
                    Text("聲音不會自己停，走過去比較快。")
                        .font(.caption2)
                        .foregroundStyle(WakeStyle.ink.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                ChecklistBlock(state: entry.state)
            }
        }
    }
}

/// 中尺寸右半邊：睡前檢查＋憑證剩餘天數
struct ChecklistBlock: View {
    let state: PoCState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("睡前檢查")
                .font(.caption.weight(.bold))
                .foregroundStyle(WakeStyle.dim)
            CheckLine(title: "QR Code", ok: state.qrToken != nil)
            CheckLine(title: "引導密碼", ok: state.guidedPasscode != nil)
            CheckLine(title: "鬧鐘權限", ok: state.alarmAuthorized)
            profileLine
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var profileLine: some View {
        if let expiry = state.profileExpiration {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundStyle(days < 30 ? WakeStyle.accent : WakeStyle.dim)
                Text("憑證剩 \(days) 天")
                    .font(.caption)
                    .foregroundStyle(days < 30 ? WakeStyle.accent : .white)
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.caption2).foregroundStyle(WakeStyle.dim)
                Text("憑證：開 App 更新").font(.caption).foregroundStyle(WakeStyle.dim)
            }
        }
    }
}

struct CheckLine: View {
    let title: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(ok ? Color.green : WakeStyle.accent)
            Text(title)
                .font(.caption)
                .foregroundStyle(ok ? Color.white : WakeStyle.accent)
        }
    }
}

// MARK: 鎖定畫面尺寸

struct RectangularView: View {
    let entry: StatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch entry.mode {
            case .idle:
                Label("今晚還沒設鬧鐘", systemImage: "moon.zzz.fill").font(.headline)
                Text("點一下去設定 ›").font(.caption)
            case .armed(let alarm):
                if let alarm {
                    Label(WakeStyle.clock.string(from: alarm), systemImage: "alarm.fill").font(.headline)
                    Text("還有 \(alarm, style: .relative)").font(.caption)
                } else {
                    Label("已上膛", systemImage: "alarm.fill").font(.headline)
                }
                Text("📍\(entry.location)掃碼").font(.caption)
            case .ringing(let since):
                Label("去\(entry.location)掃碼", systemImage: "figure.walk").font(.headline)
                Text(since, style: .timer).font(.caption).monospacedDigit()
                Text("被關 \(entry.state.rearmCount) 次").font(.caption)
            case .awake:
                Label("今天起床了", systemImage: "sun.max.fill").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CircularView: View {
    let entry: StatusEntry

    var body: some View {
        VStack(spacing: 1) {
            switch entry.mode {
            case .idle:
                Image(systemName: "moon.zzz.fill").font(.title3)
                Text("未設").font(.caption2)
            case .armed(let alarm):
                Image(systemName: "alarm.fill").font(.caption)
                if let alarm {
                    Text(WakeStyle.clock.string(from: alarm))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                }
            case .ringing:
                Image(systemName: "figure.walk").font(.title3)
                Text("掃碼").font(.caption2.weight(.bold))
            case .awake:
                Image(systemName: "sun.max.fill").font(.title3)
                Text("起床").font(.caption2)
            }
        }
    }
}

struct InlineView: View {
    let entry: StatusEntry

    var body: some View {
        switch entry.mode {
        case .idle:
            Label("今晚還沒設鬧鐘", systemImage: "moon.zzz.fill")
        case .armed(let alarm):
            Label(alarm.map { "\(WakeStyle.clock.string(from: $0)) · \(entry.location)掃碼" } ?? "已上膛",
                  systemImage: "alarm.fill")
        case .ringing:
            Label("去\(entry.location)掃碼！", systemImage: "figure.walk")
        case .awake:
            Label("今天起床了", systemImage: "sun.max.fill")
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WakeStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("起床")
        .description("鬧鐘時間、倒數與睡前檢查")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - AlarmKit 的即時動態（鎖屏 / 動態島）
// 系統自帶的「停止」按鈕無法移除（按了由 StopAlarmIntent 重排）。

struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeMetadata>.self) { context in
            LiveRingView(meta: context.attributes.metadata)
                .activityBackgroundTint(WakeStyle.background)
                .activitySystemActionForegroundColor(WakeStyle.accent)
        } dynamicIsland: { context in
            let meta = context.attributes.metadata
            let place = meta?.location ?? "客廳"
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "figure.walk")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(WakeStyle.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = meta?.ringingSince {
                        Text(since, style: .timer)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(WakeStyle.accent)
                            .frame(maxWidth: 80)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("去\(place)掃碼")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("要走過去解鎖才會停")
                        .font(.caption)
                        .foregroundStyle(WakeStyle.dim)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(WakeStyle.accent)
            } compactTrailing: {
                if let since = meta?.ringingSince {
                    Text(since, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(WakeStyle.accent)
                        .frame(maxWidth: 52)
                } else {
                    Text("掃碼").foregroundStyle(WakeStyle.accent)
                }
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(WakeStyle.accent)
            }
            .keylineTint(WakeStyle.accent)
        }
    }
}

struct LiveRingView: View {
    let meta: WakeMetadata?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.walk")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(WakeStyle.background)
                .frame(width: 52, height: 52)
                .background(WakeStyle.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("去\(meta?.location ?? "客廳")掃碼")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                if let since = meta?.ringingSince {
                    HStack(spacing: 4) {
                        Text("已響")
                        Text(since, style: .timer).monospacedDigit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WakeStyle.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - 控制中心按鈕：只打開 App

struct WakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "WakeOpenControl") {
            ControlWidgetButton(action: OpenWakeAppIntent()) {
                Label("起床", systemImage: "alarm.fill")
            }
        }
        .displayName("起床")
        .description("打開起床 App")
    }
}
