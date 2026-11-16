import SwiftUI
import AlarmKit
import Observation

@MainActor
@Observable
final class AppModel {
    var state = Store.load()
    var alarms: [Alarm] = []
    var authState = "未知"
    var lastUID = "—"
    var scanning = false
    var showQRScanner = false
    var showQRCode = false

    /// 上膛中（任務未完成）鎖住設定與重置，避免半夢半醒的自己關掉
    var locked: Bool { state.phase.missionPending }

    @ObservationIgnored private var registerMode = false
    @ObservationIgnored private let scanner = NFCScanner()
    @ObservationIgnored private var observer: Task<Void, Never>?

    var appGroupText: String {
        if let group = AppGroup.resolved { return "✅ \(group.id)" }
        return "❌ 無（改用 App 私有目錄）"
    }

    var profileText: String {
        guard let date = ProvisioningInfo.expirationDate else { return "讀不到 profile" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return "剩 \(days) 天（\(date.formatted(date: .numeric, time: .omitted))）"
    }

    var profileWarning: Bool {
        guard let date = ProvisioningInfo.expirationDate else { return false }
        return date.timeIntervalSinceNow < 14 * 86_400
    }

    // MARK: 生命週期

    func refresh() {
        state = Store.load()
        alarms = (try? AlarmManager.shared.alarms) ?? []
        authState = "\(AlarmManager.shared.authorizationState)"
    }

    func onActive() {
        refresh()
        startObserving()
        let list = alarms.map(AlarmController.describe).joined(separator: ", ")
        Log.write("👀 進前景 phase=\(state.phase.rawValue) 系統內鬧鐘 \(alarms.count) 顆 [\(list)]")
        if state.pendingScan {
            state = Store.update { $0.pendingScan = false }
            beginUnlock()
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = Task {
            for await list in AlarmManager.shared.alarmUpdates {
                let desc = list.map(AlarmController.describe).joined(separator: ", ")
                Log.write("📡 alarmUpdates [\(desc)]")
                self.alarms = list
            }
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<PoCState, T>) -> Binding<T> {
        Binding(
            get: { self.state[keyPath: keyPath] },
            set: { value in self.state = Store.update { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: 上膛 / 重置

    func arm(after seconds: TimeInterval) {
        Task {
            guard await AlarmController.ensureAuthorized() else { refresh(); return }
            state = Store.update {
                $0.phase = .armed
                $0.rearmCount = 0
                $0.pendingScan = false
            }
            do {
                try await AlarmController.schedule(after: seconds, reason: "手動上膛")
            } catch {
                Log.write("❌ 排程失敗：\(error)")
            }
            refresh()
        }
    }

    func arm(at time: Date) {
        var interval = time.timeIntervalSinceNow
        if interval < 5 { interval += 86_400 }
        arm(after: interval)
    }

    func resetAll() {
        guard !locked else {
            Log.write("⛔️ 上膛中不能重置")
            return
        }
        // 先改狀態，避免正在執行的 stopIntent 又重排
        state = Store.update {
            $0.phase = .idle
            $0.pendingScan = false
        }
        AlarmController.cancelAll(reason: "手動重置")
        refresh()
    }

    // MARK: 解鎖

    func beginUnlock() {
        switch state.unlockMethod {
        case .qr: showQRScanner = true
        case .nfc: startScan()
        }
    }

    private func verifySuccess(source: String) {
        guard state.phase.missionPending else {
            Log.write("✅ \(source) 正確（目前未上膛，只是測試）")
            return
        }
        state = Store.update {
            $0.phase = .verified
            $0.pendingScan = false
        }
        AlarmController.cancelAll(reason: "\(source) 驗證成功")
        Log.write("✅ \(source) 驗證成功，鬧鐘解除")
        refresh()
    }

    // MARK: QR

    func generateQRToken() {
        let token = "WAKEUP-" + UUID().uuidString
        state = Store.update { $0.qrToken = token }
        Log.write("🔳 產生新的 QR Code")
    }

    func handleQR(_ payload: String) {
        showQRScanner = false
        guard let token = state.qrToken else {
            Log.write("❌ 還沒產生 QR Code")
            return
        }
        if payload == token {
            verifySuccess(source: "QR")
        } else {
            Log.write("❌ QR 內容不符")
        }
    }

    // MARK: NFC

    func startScan(register: Bool = false) {
        registerMode = register
        scanning = true
        scanner.scan { result in
            Task { @MainActor in self.handle(result) }
        }
    }

    private func handle(_ result: Result<String, Error>) {
        scanning = false
        switch result {
        case .failure(let error):
            Log.write("NFC 失敗：\(error.localizedDescription)")
        case .success(let uid):
            lastUID = uid
            if registerMode {
                registerMode = false
                state = Store.update {
                    if !$0.nfcWhitelist.contains(uid) { $0.nfcWhitelist.append(uid) }
                }
                Log.write("🏷️ 登錄標籤 \(uid)")
            } else if state.nfcWhitelist.contains(uid) {
                verifySuccess(source: "NFC 標籤 \(uid)")
            } else {
                Log.write("❌ 標籤 \(uid) 不在白名單")
            }
        }
        refresh()
    }

    func removeTag(_ uid: String) {
        state = Store.update { $0.nfcWhitelist.removeAll { $0 == uid } }
    }
}
