import Foundation
import SwiftUI
import AlarmKit
import ActivityKit
import AppIntents

struct WakeMetadata: AlarmMetadata {
    var label: String = "wake"
}

enum AlarmController {
    static func ensureAuthorized() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            Log.write("⚠️ AlarmKit 權限被拒，請到 設定 > 起床 開啟")
            return false
        default:
            do {
                let result = try await manager.requestAuthorization()
                Log.write("AlarmKit 授權結果：\(result)")
                return result == .authorized
            } catch {
                Log.write("❌ AlarmKit 授權錯誤：\(error)")
                return false
            }
        }
    }

    /// 排一顆「現在 + seconds」的系統級鬧鐘。
    /// 取消現有的全部鬧鐘，重排一整串：第一顆在 +seconds，之後每 chainSeconds 一顆保底。
    /// 被音量鍵、側鍵等任何方式弄安靜，下一顆保底照響；只有驗證成功能全部取消。
    static func scheduleSequence(startIn seconds: TimeInterval, reason: String) async {
        // 拿一個新編號；之前還在跑的排程迴圈看到編號變了就會停
        let state = Store.update { $0.sequenceGeneration += 1 }
        let generation = state.sequenceGeneration
        cancelAll(reason: "重排序列（\(reason)）", log: false)
        let count = max(1, state.chainCount)
        var ok = 0
        var failed = 0
        for i in 0..<count {
            let latest = Store.load()
            guard latest.sequenceGeneration == generation, latest.phase.missionPending else {
                Log.write("⛔️ 排程中止（已解除或有更新的排程），已排 \(ok) 顆")
                if !latest.phase.missionPending { cancelAll(reason: "中止後清掉已排的", log: false) }
                return
            }
            let offset = seconds + TimeInterval(i * state.chainSeconds)
            do {
                try await schedule(after: offset, reason: reason, log: i == 0)
                ok += 1
            } catch {
                failed += 1
                if failed == 1 { Log.write("❌ 第 \(i + 1) 顆排程失敗：\(error)") }
            }
        }
        Log.write("⛓️ 排好 \(ok) 顆（首顆 +\(Int(seconds))s，之後每 \(state.chainSeconds)s 一顆），失敗 \(failed) 顆")
    }

    @discardableResult
    static func schedule(after seconds: TimeInterval, reason: String, log: Bool = true) async throws -> UUID {
        let id = UUID()
        let fireDate = Date().addingTimeInterval(seconds)

        let stopButton = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        let scanButton = AlarmButton(text: "去掃描", textColor: .white, systemImageName: "figure.walk")
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "起床！去\(Store.load().scanLocation)掃碼"),
            stopButton: stopButton,
            secondaryButton: scanButton,
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<WakeMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: WakeMetadata(),
            tintColor: .red
        )
        let configuration = AlarmManager.AlarmConfiguration<WakeMetadata>(
            countdownDuration: nil,
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: StopAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: GoScanIntent(alarmID: id.uuidString),
            sound: Store.load().customSound ? .named("wake_alarm.wav") : .default
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        if log { Log.write("⏰ 排程 \(id.short) 於 \(Log.formatter.string(from: fireDate))（+\(Int(seconds))s）原因：\(reason)") }
        return id
    }

    /// 驗證成功後：讓排程迴圈全部失效，取消全部，並在幾秒內再補清幾次漏網的
    static func disarm(reason: String) {
        Store.update { $0.sequenceGeneration += 1 }
        cancelAll(reason: reason)
        Task {
            for delay in [1, 3, 6] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Store.load().phase.missionPending else { return }
                let left = (try? AlarmManager.shared.alarms) ?? []
                if !left.isEmpty { cancelAll(reason: "補清漏網 \(left.count) 顆") }
            }
        }
    }

    static func cancelAll(reason: String, log: Bool = true) {
        let list = (try? AlarmManager.shared.alarms) ?? []
        for alarm in list {
            do { try AlarmManager.shared.cancel(id: alarm.id) }
            catch { Log.write("取消 \(alarm.id.short) 失敗：\(error)") }
        }
        if log { Log.write("🧹 取消全部鬧鐘（\(list.count) 顆），原因：\(reason)") }
    }

    static func describe(_ alarm: Alarm) -> String {
        "\(alarm.id.short) · \(alarm.state)"
    }

    static func isAlerting(_ alarm: Alarm) -> Bool {
        "\(alarm.state)" == "alerting"
    }

    /// 例：「共 180 顆（響鈴中 1）」
    static func summary(_ list: [Alarm]) -> String {
        let alerting = list.filter(isAlerting).count
        return alerting > 0 ? "共 \(list.count) 顆（響鈴中 \(alerting)）" : "共 \(list.count) 顆"
    }
}

// MARK: - 鬧鐘按鈕的 Intent（系統會在背景喚醒 App 執行）

/// 按「停止」：任務沒完成就 N 秒後重響。
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止鬧鐘"
    static var isDiscoverable: Bool = false

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) { self.alarmID = alarmID }
    init() { self.alarmID = "" }

    func perform() async throws -> some IntentResult {
        let state = Store.load()
        Log.write("🛑 stopIntent alarm=\(alarmID.prefix(8)) phase=\(state.phase.rawValue) callStop=\(state.callStopInIntent)")

        if state.callStopInIntent, let id = UUID(uuidString: alarmID) {
            do { try AlarmManager.shared.stop(id: id) }
            catch { Log.write("stop() 失敗：\(error)") }
        }

        if state.phase.missionPending && state.stopRearmEnabled {
            Store.update { $0.rearmCount += 1 }
            await AlarmController.scheduleSequence(
                startIn: TimeInterval(state.rearmSeconds),
                reason: "按停止 → \(state.rearmSeconds)s 後重響"
            )
        }
        return .result()
    }
}

/// 按「去掃描」：停掉這次響鈴、排緩衝鬧鐘、打開 App 自動開始掃描（QR 或 NFC）。
struct GoScanIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "去掃描"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) { self.alarmID = alarmID }
    init() { self.alarmID = "" }

    func perform() async throws -> some IntentResult {
        let state = Store.load()
        Log.write("🚶 goScanIntent alarm=\(alarmID.prefix(8)) phase=\(state.phase.rawValue)")

        guard state.phase.missionPending else {
            if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
            return .result()
        }

        // 先設旗標並通知 App，讓相機盡快跳出來，再慢慢排鬧鐘
        Store.update {
            $0.phase = .buffer
            $0.pendingScan = true
        }
        CrossProcess.postPendingScan()

        // 重排會取消全部（包含正在響的這顆）
        await AlarmController.scheduleSequence(
            startIn: TimeInterval(state.bufferSeconds),
            reason: "緩衝 \(state.bufferSeconds)s 到了還沒掃到"
        )
        return .result()
    }
}
