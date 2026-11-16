import AppIntents
import Foundation

/// 捷徑／Siri 上膛。安全底線：已上膛或響鈴中一律拒絕，免得半夢半醒用 Siri 把鬧鐘改晚。
/// 這裡只能「上膛」，沒有停止、解除、延後的動作。
struct ArmAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "上膛起床鬧鐘"
    static var description = IntentDescription("設定下一次的起床時間並上膛。已上膛或響鈴中不能改。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "時", inclusiveRange: (0, 23))
    var hour: Int

    @Parameter(title: "分", inclusiveRange: (0, 59))
    var minute: Int

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("在 \(\.$hour) 時 \(\.$minute) 分上膛")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = Store.load()
        if state.phase.missionPending {
            Log.write("⛔️ 捷徑上膛被拒：鬧鐘進行中（\(hour):\(minute)）")
            return .result(dialog: Self.dialog("鬧鐘進行中，不能改時間"))
        }
        guard state.qrToken != nil else {
            return .result(dialog: Self.dialog("還沒設定 QR Code，請先在 App 裡產生"))
        }
        let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        let fire = AppModel.nextOccurrence(of: time)
        guard await AppModel.performArm(after: fire.timeIntervalSinceNow, source: "捷徑") else {
            return .result(dialog: Self.dialog("鬧鐘權限沒開，請到 設定 > 起床 允許"))
        }
        let day = Calendar.current.isDateInToday(fire) ? "今天" : "明天"
        let text = String(format: "%02d:%02d", hour, minute)
        return .result(dialog: Self.dialog("已上膛：\(day) \(text) 響，去\(state.scanLocation)掃碼才會停"))
    }

    private static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: text))
    }
}

struct WakeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ArmAlarmIntent(),
            phrases: [
                "用\(.applicationName)設鬧鐘",
                "\(.applicationName)上膛",
            ],
            shortTitle: "上膛",
            systemImageName: "alarm.fill"
        )
    }
}
