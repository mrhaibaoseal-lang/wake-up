import Foundation

/// 一晚的紀錄。睡眠時數 = 上膛到掃碼（沒有手錶，上膛後還在滑手機的時間也會算進去）。
struct NightRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var armedAt: Date          // 按上膛的時間，當作上床
    var alarmAt: Date          // 預定響的時間
    var verifiedAt: Date? = nil
    var rearmCount: Int = 0

    /// 有效的睡眠時數（1～16 小時之外視為無效，例如快速測試）
    var sleepHours: Double? {
        guard let verifiedAt else { return nil }
        let hours = verifiedAt.timeIntervalSince(armedAt) / 3600
        return (1...16).contains(hours) ? hours : nil
    }

    /// 響鈴到掃碼花幾分鐘（只算有效的一晚，快速測試不算）
    var wakeMinutes: Double? {
        guard let verifiedAt, sleepHours != nil else { return nil }
        return max(0, verifiedAt.timeIntervalSince(alarmAt) / 60)
    }
}

/// 存在 App Group 的 nights.json，只留最近 60 天。只有 App 會讀寫（小工具不顯示睡眠資料）。
enum SleepStore {
    private static let queue = DispatchQueue(label: "wakeup.nights")
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("nights.json") }
    static let keepDays: Double = 60

    static func load() -> [NightRecord] {
        queue.sync { loadUnlocked() }
    }

    private static func loadUnlocked() -> [NightRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([NightRecord].self, from: data)
        else { return [] }
        return list
    }

    private static func modify(_ body: (inout [NightRecord]) -> Void) {
        queue.sync {
            var list = loadUnlocked()
            body(&list)
            let cutoff = Date().addingTimeInterval(-keepDays * 86_400)
            list.removeAll { $0.armedAt < cutoff }
            list.sort { $0.armedAt < $1.armedAt }
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 上膛：之前沒驗證的（重新上膛前遺留的）先丟掉，再建立新的一筆
    static func startNight(armedAt: Date, alarmAt: Date) {
        modify { list in
            list.removeAll { $0.verifiedAt == nil }
            list.append(NightRecord(armedAt: armedAt, alarmAt: alarmAt))
        }
    }

    /// 掃碼驗證成功：補上驗證時間與被關次數
    static func finishNight(verifiedAt: Date, rearmCount: Int) {
        modify { list in
            guard let index = list.lastIndex(where: { $0.verifiedAt == nil }) else { return }
            list[index].verifiedAt = verifiedAt
            list[index].rearmCount = rearmCount
        }
    }

    /// 手動重置（沒驗證）：刪掉這筆
    static func discardPending() {
        modify { list in list.removeAll { $0.verifiedAt == nil } }
    }
}

/// 睡眠頁用的統計。一週從週一開始，紀錄歸屬到掃碼那天。
struct SleepStats {
    struct Day: Identifiable {
        let date: Date          // 那天 00:00
        let label: String       // 一、二…日
        let hours: Double?
        let wakeMinutes: Double?
        let rearmCount: Int
        var id: Date { date }
    }

    let days: [Day]             // 本週一到日
    let totalHours: Double
    let averageHours: Double?
    let fastStreak: Int         // 連續幾天 10 分鐘內掃碼

    static let fastLimit: Double = 10

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2  // 週一
        c.locale = Locale(identifier: "zh_Hant_TW")
        return c
    }

    init(records: [NightRecord], now: Date = Date()) {
        let cal = Self.calendar
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)

        func dayRecords(_ day: Date) -> [NightRecord] {
            records.filter { r in
                guard let v = r.verifiedAt, r.sleepHours != nil else { return false }
                return cal.isDate(v, inSameDayAs: day)
            }
        }

        var days: [Day] = []
        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: weekStart) else { continue }
            let list = dayRecords(day)
            let hours = list.isEmpty ? nil : list.compactMap(\.sleepHours).reduce(0, +)
            let first = list.min { ($0.verifiedAt ?? .distantFuture) < ($1.verifiedAt ?? .distantFuture) }
            days.append(Day(date: day, label: labels[i], hours: hours,
                            wakeMinutes: first?.wakeMinutes, rearmCount: first?.rearmCount ?? 0))
        }
        self.days = days

        let counted = days.compactMap(\.hours)
        totalHours = counted.reduce(0, +)
        averageHours = counted.isEmpty ? nil : totalHours / Double(counted.count)

        // 連續天數：今天還沒紀錄就從昨天開始算
        var streak = 0
        var cursor = cal.startOfDay(for: now)
        if dayRecords(cursor).isEmpty, let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while true {
            let list = dayRecords(cursor)
            guard let minutes = list.compactMap(\.wakeMinutes).min(), minutes <= Self.fastLimit else { break }
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        fastStreak = streak
    }

    static func hoursText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) 小時 \(minutes % 60) 分"
    }
}
