import Foundation
import WidgetKit

// MARK: - 讀取自己的 embedded.mobileprovision（到期日、App Group 清單）

enum ProvisioningInfo {
    static let plist: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: slice, format: nil)) as? [String: Any]
    }()

    static var expirationDate: Date? { plist?["ExpirationDate"] as? Date }

    static var appGroups: [String] {
        let ent = plist?["Entitlements"] as? [String: Any]
        return ent?["com.apple.security.application-groups"] as? [String] ?? []
    }
}

// MARK: - App Group：不寫死，啟動時找第一個真的能讀寫的

enum AppGroup {
    /// 來自 Flarestore profile 的群組，當作 embedded.mobileprovision 讀不到時的備援
    static let fallback = [
        "group.81c139ae9a27a7f8.1",
        "group.81c139ae9a27a7f8.2",
        "group.81c139ae9a27a7f8.3",
        "group.81c139ae9a27a7f8.4",
        "group.81c139ae9a27a7f8.5",
    ]

    static let resolved: (id: String, url: URL)? = {
        var candidates = ProvisioningInfo.appGroups.sorted()
        for g in fallback where !candidates.contains(g) { candidates.append(g) }
        for id in candidates {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { continue }
            let probe = url.appendingPathComponent(".probe")
            if (try? Data("ok".utf8).write(to: probe, options: .atomic)) != nil {
                return (id, url)
            }
        }
        return nil
    }()

    static var containerURL: URL {
        if let url = resolved?.url { return url }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 記錄（App 與 Widget 共用同一個檔案）

enum Log {
    private static let queue = DispatchQueue(label: "wakeup.log")
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("poc.log") }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var processTag: String {
        Bundle.main.bundlePath.hasSuffix(".appex") ? "widget" : "app"
    }

    /// 記錄檔上限；超過就只保留後半段
    private static let maxBytes = 200_000

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))][\(processTag)] \(message)\n"
        let data = Data(line.utf8)
        queue.sync {
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                let end = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: data)
                try? handle.close()
                if end > UInt64(maxBytes) { trimUnlocked() }
            } else {
                try? data.write(to: url)
            }
        }
        print(line, terminator: "")
    }

    private static func trimUnlocked() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        var output = Data("（較舊的記錄已自動刪除）\n".utf8)
        output.append(tail)
        try? output.write(to: fileURL, options: .atomic)
    }

    static func readAll() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    /// 最後 n 行（給記錄頁顯示用）
    static func tailLines(_ n: Int) -> [String] {
        let lines = readAll().split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(n).map(String.init)
    }

    static func lastLine() -> String {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > 4096 ? size - 4096 : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n").last.map(String.init) ?? ""
        }
    }

    static func clear() {
        queue.sync { _ = try? FileManager.default.removeItem(at: fileURL) }
    }
}

// MARK: - 狀態（持久化在 App Group，App 被殺後可還原）

enum Phase: String, Codable {
    case idle      // 未上膛
    case armed     // 已上膛 / 響鈴中，任務未完成
    case buffer    // 按了「去掃描」，緩衝倒數中
    case verified  // NFC 驗證成功

    var title: String {
        switch self {
        case .idle: return "未上膛"
        case .armed: return "已上膛／響鈴中"
        case .buffer: return "緩衝中（去掃描）"
        case .verified: return "已驗證 ✅"
        }
    }

    /// 任務還沒完成：按停止要重排
    var missionPending: Bool { self == .armed || self == .buffer }

}

enum UnlockMethod: String, Codable {
    case qr
    case nfc

    /// 畫面文字用：「掃 QR Code」「感應 NFC 卡片」
    var actionText: String { self == .qr ? "掃 QR Code" : "感應 NFC 卡片" }
}

struct PoCState: Codable {
    var phase: Phase = .idle
    var rearmCount: Int = 0
    var rearmSeconds: Int = 15
    var bufferSeconds: Int = 45
    var stopRearmEnabled: Bool = true
    var callStopInIntent: Bool = true
    var pendingScan: Bool = false
    var nfcWhitelist: [String] = []
    var unlockMethod: UnlockMethod = .qr
    var qrToken: String? = nil
    var alarmSound: String = AlarmSound.defaultChoice // 鬧鐘聲音：內建檔名、匯入的檔名，或 AlarmSound.systemDefault
    var keepScreenOn: Bool = true     // 上膛後禁止自動鎖定（關掉才能用引導模式的「螢幕自動鎖定」）
    var scanLocation: String = "客廳"   // QR Code 貼的位置（只用於顯示文字）
    var guidedPasscode: String? = nil  // 引導使用模式密碼：上膛中隱藏，掃碼成功後才顯示
    var chainSeconds: Int = 120  // 保底鬧鐘間隔（鬧鐘疊在一起會只剩震動，所以預設只排 1 顆）
    var chainCount: Int = 1      // 保底鬧鐘顆數
    var refreshSeconds: Int = 10 // 響了幾秒還沒解除就換一顆新的（0 = 關閉）
    var sirenEnabled: Bool = true // 時間到後 App 自己播警報聲（按鍵停不掉）
    var alarmDate: Date? = nil    // 這次上膛預定第一次響的時間
    var sequenceGeneration: Int = 0  // 每次重排 +1，舊的排程迴圈看到就停
    var verifiedAt: Date? = nil       // 最近一次掃碼驗證成功的時間（小工具顯示「今天起床了」）
    var alarmAuthorized: Bool = false // App 存下的鬧鐘權限結果（小工具自己讀不到）
    var profileExpiration: Date? = nil // App 存下的憑證到期日（小工具讀不到 embedded.mobileprovision）
    var bedtimeReminderOn: Bool = true  // 睡前提醒「今晚還沒上膛」
    var bedtimeMinutes: Int = 23 * 60 + 30 // 睡前提醒時間（一天中的第幾分鐘），預設 23:30
    var weatherLatitude: Double? = nil   // 天氣位置（只存在手機，四捨五入到小數 2 位約 1 公里）
    var weatherLongitude: Double? = nil
    var heatTolerance: HeatTolerance = .hot // 穿衣體質（使用者怕熱）
    var weatherUntilHour: Int = 22          // 穿衣建議考慮到幾點
    var wakeSpeechOn: Bool = true           // 解鎖成功後語音播報天氣
    var cwaKey: String = ""                 // 中央氣象署開放資料授權碼（只存在手機，不能進 repo）
    var cwaDataset: String? = nil           // 依天氣位置找到的縣市資料集，例如 F-D0047-061
    var cwaCounty: String? = nil            // 例如 臺北市
    var cwaTown: String? = nil              // 例如 大安區
    var lastUpdated: Date = Date()

    init() {}

    private enum LegacyKeys: String, CodingKey { case customSound }

    // 新增欄位時舊資料仍可讀（缺的欄位用預設值），避免白名單被清掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PoCState()
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? d.phase
        rearmCount = try c.decodeIfPresent(Int.self, forKey: .rearmCount) ?? d.rearmCount
        rearmSeconds = try c.decodeIfPresent(Int.self, forKey: .rearmSeconds) ?? d.rearmSeconds
        bufferSeconds = try c.decodeIfPresent(Int.self, forKey: .bufferSeconds) ?? d.bufferSeconds
        stopRearmEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopRearmEnabled) ?? d.stopRearmEnabled
        callStopInIntent = try c.decodeIfPresent(Bool.self, forKey: .callStopInIntent) ?? d.callStopInIntent
        pendingScan = try c.decodeIfPresent(Bool.self, forKey: .pendingScan) ?? d.pendingScan
        nfcWhitelist = try c.decodeIfPresent([String].self, forKey: .nfcWhitelist) ?? d.nfcWhitelist
        unlockMethod = try c.decodeIfPresent(UnlockMethod.self, forKey: .unlockMethod) ?? d.unlockMethod
        qrToken = try c.decodeIfPresent(String.self, forKey: .qrToken)
        guidedPasscode = try c.decodeIfPresent(String.self, forKey: .guidedPasscode)
        scanLocation = try c.decodeIfPresent(String.self, forKey: .scanLocation) ?? d.scanLocation
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? d.keepScreenOn
        if let sound = try c.decodeIfPresent(String.self, forKey: .alarmSound) {
            alarmSound = sound
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  (try? legacy.decodeIfPresent(Bool.self, forKey: .customSound)) == false {
            alarmSound = AlarmSound.systemDefault  // 舊版關掉「刺耳警報音」的人維持系統鈴聲
        } else {
            alarmSound = d.alarmSound
        }
        chainSeconds = try c.decodeIfPresent(Int.self, forKey: .chainSeconds) ?? d.chainSeconds
        chainCount = try c.decodeIfPresent(Int.self, forKey: .chainCount) ?? d.chainCount
        sequenceGeneration = try c.decodeIfPresent(Int.self, forKey: .sequenceGeneration) ?? d.sequenceGeneration
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? d.refreshSeconds
        sirenEnabled = try c.decodeIfPresent(Bool.self, forKey: .sirenEnabled) ?? d.sirenEnabled
        alarmDate = try c.decodeIfPresent(Date.self, forKey: .alarmDate)
        verifiedAt = try c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        alarmAuthorized = try c.decodeIfPresent(Bool.self, forKey: .alarmAuthorized) ?? d.alarmAuthorized
        profileExpiration = try c.decodeIfPresent(Date.self, forKey: .profileExpiration)
        bedtimeReminderOn = try c.decodeIfPresent(Bool.self, forKey: .bedtimeReminderOn) ?? d.bedtimeReminderOn
        bedtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .bedtimeMinutes) ?? d.bedtimeMinutes
        weatherLatitude = try c.decodeIfPresent(Double.self, forKey: .weatherLatitude)
        weatherLongitude = try c.decodeIfPresent(Double.self, forKey: .weatherLongitude)
        heatTolerance = (try? c.decodeIfPresent(HeatTolerance.self, forKey: .heatTolerance)) ?? d.heatTolerance
        weatherUntilHour = try c.decodeIfPresent(Int.self, forKey: .weatherUntilHour) ?? d.weatherUntilHour
        wakeSpeechOn = try c.decodeIfPresent(Bool.self, forKey: .wakeSpeechOn) ?? d.wakeSpeechOn
        cwaKey = try c.decodeIfPresent(String.self, forKey: .cwaKey) ?? d.cwaKey
        cwaDataset = try c.decodeIfPresent(String.self, forKey: .cwaDataset)
        cwaCounty = try c.decodeIfPresent(String.self, forKey: .cwaCounty)
        cwaTown = try c.decodeIfPresent(String.self, forKey: .cwaTown)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? d.lastUpdated
    }
}

/// 鬧鐘聲音的共用常數（App、Widget、Intent 都會用到）
enum AlarmSound {
    /// 系統預設鈴聲（AlarmKit `.default`）
    static let systemDefault = "default"
    /// 預設選最刺耳的內建音；也是 App 警報聲在「系統預設」或檔案遺失時的替代
    static let defaultChoice = "wake_scream.wav"
}

enum Store {
    private static let queue = DispatchQueue(label: "wakeup.store")
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("state.json") }

    static func load() -> PoCState {
        queue.sync { loadUnlocked() }
    }

    private static func loadUnlocked() -> PoCState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PoCState.self, from: data)
        else { return PoCState() }
        return state
    }

    @discardableResult
    static func update(_ body: (inout PoCState) -> Void) -> PoCState {
        let state: PoCState = queue.sync {
            var s = loadUnlocked()
            body(&s)
            s.lastUpdated = Date()
            if let data = try? JSONEncoder().encode(s) {
                try? data.write(to: fileURL, options: .atomic)
            }
            return s
        }
        WidgetCenter.shared.reloadAllTimelines()
        return state
    }
}

// MARK: - 跨程序通知：「去掃描」按下時立刻叫醒前景的 App

extension Notification.Name {
    static let wakePendingScan = Notification.Name("wakePendingScan")
}

enum CrossProcess {
    private static let darwinName = "app.calcite3909.scorpio3556.pendingScan" as CFString

    static func postPendingScan() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName), nil, nil, true
        )
    }

    static func observePendingScan() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: .wakePendingScan, object: nil)
            },
            darwinName, nil, .deliverImmediately
        )
    }
}

extension UUID {
    var short: String { String(uuidString.prefix(8)) }
}
