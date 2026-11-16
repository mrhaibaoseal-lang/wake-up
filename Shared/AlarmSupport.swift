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
    @discardableResult
    static func schedule(after seconds: TimeInterval, reason: String) async throws -> UUID {
        let id = UUID()
        let fireDate = Date().addingTimeInterval(seconds)

        let stopButton = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        let scanButton = AlarmButton(text: "去掃描", textColor: .white, systemImageName: "figure.walk")
        let alert = AlarmPresentation.Alert(
            title: "起床！去浴室掃碼",
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
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        Log.write("⏰ 排程 \(id.short) 於 \(Log.formatter.string(from: fireDate))（+\(Int(seconds))s）原因：\(reason)")
        return id
    }

    static func cancelAll(reason: String) {
        let list = (try? AlarmManager.shared.alarms) ?? []
        for alarm in list {
            do { try AlarmManager.shared.cancel(id: alarm.id) }
            catch { Log.write("取消 \(alarm.id.short) 失敗：\(error)") }
        }
        Log.write("🧹 取消全部鬧鐘（\(list.count) 顆），原因：\(reason)")
    }

    static func describe(_ alarm: Alarm) -> String {
        "\(alarm.id.short) · \(alarm.state)"
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
            try await AlarmController.schedule(
                after: TimeInterval(state.rearmSeconds),
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

        if let id = UUID(uuidString: alarmID) {
            do { try AlarmManager.shared.stop(id: id) }
            catch { Log.write("stop() 失敗：\(error)") }
        }

        if state.phase.missionPending {
            Store.update {
                $0.phase = .buffer
                $0.pendingScan = true
            }
            try await AlarmController.schedule(
                after: TimeInterval(state.bufferSeconds),
                reason: "緩衝 \(state.bufferSeconds)s 到了還沒掃到"
            )
        }
        return .result()
    }
}
