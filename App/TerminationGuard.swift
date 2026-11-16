import UIKit
import UserNotifications
import AlarmKit

/// App 被滑掉（上膛中）時的備援：排一顆新的鬧鐘，再排一串時效性通知。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        TerminationGuard.handle()
    }
}

enum TerminationGuard {
    static func handle() {
        let state = Store.load()
        guard state.phase.missionPending else { return }
        Log.write("💀 App 在上膛中被滑掉 → 啟動備援")

        // 1. 通知連發（最快，先排）
        NotificationBurst.schedule()

        // 2. 取消正在響（可能已被靜音）的鬧鐘，2 秒後換一顆新的（新的才有聲音）
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await AlarmController.scheduleSequence(startIn: 2, reason: "App 被滑掉")
            done.signal()
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            Log.write("⚠️ 被滑掉時排鬧鐘逾時")
        }
    }
}

enum NotificationBurst {
    static let count = 60          // 系統上限 64 則待發通知
    static let interval: TimeInterval = 5

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.write("通知授權：\(granted ? "允許" : "拒絕")\(error.map { "（\($0)）" } ?? "")")
        }
    }

    static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let group = DispatchGroup()
        for i in 0..<count {
            let content = UNMutableNotificationContent()
            content.title = "起床！鬧鐘 App 被關掉了"
            content.body = "去浴室掃 QR Code 才會停"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3 + Double(i) * interval, repeats: false)
            group.enter()
            center.add(UNNotificationRequest(identifier: "burst-\(i)", content: content, trigger: trigger)) { _ in
                group.leave()
            }
        }
        if group.wait(timeout: .now() + 1.5) == .timedOut {
            Log.write("⚠️ 通知連發排程逾時（可能只排了一部分）")
        } else {
            Log.write("📣 排好 \(count) 則通知（每 \(Int(interval))s 一則）")
        }
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
