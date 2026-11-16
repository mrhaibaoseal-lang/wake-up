import Foundation
import UserNotifications

/// 睡前提醒：一次排未來 7 天的單次通知「今晚還沒上膛」。
/// 只動 `bedtime-` 開頭的通知，不碰 NotificationBurst 的 `burst-`。
/// 注意：NotificationBurst.clear()／schedule() 會清掉全部待發通知，所以重置、驗證後都要重排。
enum BedtimeReminder {
    static let prefix = "bedtime-"

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// 依目前 state 重排（App 回前景、上膛、重置、驗證、改設定時呼叫）
    static func reschedule() {
        Task { await rescheduleNow() }
    }

    static func rescheduleNow() async {
        let state = Store.load()
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)

        guard state.bedtimeReminderOn else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let calendar = Calendar.current
        let now = Date()
        let hour = state.bedtimeMinutes / 60
        let minute = state.bedtimeMinutes % 60
        // 已上膛：鬧鐘響之前的那則（今晚的）不用提醒
        let skipBefore = state.phase.missionPending ? (state.alarmDate ?? .distantFuture) : .distantPast
        var added = 0
        for offset in 0..<8 where added < 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now, fire >= skipBefore
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = "今晚還沒上膛"
            content.body = "睡前打開起床，選好時間按上膛，再開引導使用模式。"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(
                identifier: prefix + idFormatter.string(from: fire),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            do {
                try await center.add(request)
                added += 1
            } catch {
                Log.write("❌ 睡前提醒排程失敗：\(error)")
                return
            }
        }
        Log.write("🌙 睡前提醒：排好 \(added) 則（\(String(format: "%02d:%02d", hour, minute))）")
    }
}
