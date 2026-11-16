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
    var guidedAccessOn = UIAccessibility.isGuidedAccessEnabled

    func generateGuidedPasscode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        state = Store.update { $0.guidedPasscode = code }
        Log.write("🔐 產生新的引導模式密碼")
        return code
    }

    @ObservationIgnored private var registerMode = false
    @ObservationIgnored private let scanner = NFCScanner()
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var pendingWatcher: Task<Void, Never>?
    @ObservationIgnored private var signalWatcher: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var alertingSince: [UUID: Date] = [:]
    @ObservationIgnored private var refreshing = false
    var keepAliveRunning = false

    init() {
        startRefresher()
    }

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
        Log.write("👀 進前景 phase=\(state.phase.rawValue) 系統內鬧鐘\(AlarmController.summary(alarms))")
        // 緩衝中打開 App 就直接開掃描
        if state.phase == .buffer && !state.pendingScan {
            beginUnlock()
        }
        checkPendingScan()
        startPendingWatchers()
    }

    // MARK: 刷新：響了 N 秒還沒解除，就取消它、1 秒後換一顆新的（新的才有聲音）

    private func startRefresher() {
        guard refresher == nil else { return }
        refresher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self.refreshTick()
            }
        }
    }

    private func refreshTick() async {
        let latest = Store.load()

        // 上膛期間保持 App 活著，解除後就停
        if latest.phase.missionPending { KeepAlive.shared.start() } else { KeepAlive.shared.stop() }
        keepAliveRunning = KeepAlive.shared.running

        // 時間到了還沒掃碼：App 自己播警報聲。掃描緩衝中（phase = buffer）暫停。
        let due = latest.alarmDate.map { $0 <= Date() } ?? false
        let sirenOn = latest.sirenEnabled && latest.phase == .armed && due
        KeepAlive.shared.setSiren(sirenOn)
        if sirenOn { VolumeForcer.setMax() }

        let guided = UIAccessibility.isGuidedAccessEnabled
        if guided != guidedAccessOn {
            guidedAccessOn = guided
            Log.write(guided ? "🔒 引導使用模式：開" : "🔓 引導使用模式：關")
        }
        if state.phase != latest.phase { state = latest }

        guard latest.phase.missionPending, latest.refreshSeconds > 0,
              !showQRScanner, !scanning, !refreshing else {
            alertingSince.removeAll()
            return
        }
        let list = (try? AlarmManager.shared.alarms) ?? []
        let now = Date()
        var current: [UUID: Date] = [:]
        for alarm in list where AlarmController.isAlerting(alarm) {
            current[alarm.id] = alertingSince[alarm.id] ?? now
        }
        alertingSince = current
        guard let oldest = current.values.min(),
              now.timeIntervalSince(oldest) >= Double(latest.refreshSeconds) else { return }

        refreshing = true
        alertingSince.removeAll()
        Log.write("🔄 響了 \(latest.refreshSeconds)s 還沒解除 → 換一顆新的")
        await AlarmController.scheduleSequence(startIn: 1, reason: "刷新")
        refreshing = false
    }

    func onInactive() {
        pendingWatcher?.cancel()
        pendingWatcher = nil
    }

    /// 「去掃描」可能在 App 已經開著、或比 App 打開更晚才執行完，所以要持續檢查
    private func startPendingWatchers() {
        if signalWatcher == nil {
            CrossProcess.observePendingScan()
            signalWatcher = Task {
                for await _ in NotificationCenter.default.notifications(named: .wakePendingScan) {
                    self.checkPendingScan()
                }
            }
        }
        pendingWatcher?.cancel()
        pendingWatcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.checkPendingScan()
            }
        }
    }

    private func checkPendingScan() {
        let latest = Store.load()
        guard latest.pendingScan else { return }
        state = Store.update { $0.pendingScan = false }
        Log.write("📷 收到去掃描，開啟掃描")
        beginUnlock()
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = Task {
            var lastAlerting = -1
            for await list in AlarmManager.shared.alarmUpdates {
                self.alarms = list
                // 只在「響鈴中」數量改變時記錄，避免排幾百顆時記錄爆量
                let alerting = list.filter(AlarmController.isAlerting).count
                if alerting != lastAlerting {
                    lastAlerting = alerting
                    Log.write("📡 \(AlarmController.summary(list))")
                }
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
            NotificationBurst.requestAuthorization()
            state = Store.update {
                $0.phase = .armed
                $0.rearmCount = 0
                $0.pendingScan = false
                $0.alarmDate = Date().addingTimeInterval(seconds)
            }
            await AlarmController.scheduleSequence(startIn: seconds, reason: "上膛")
            refresh()
        }
    }

    /// 下一個符合「時:分」的時間（至少 5 秒後）
    static func nextOccurrence(of time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: Date().addingTimeInterval(5), matching: parts,
                                 matchingPolicy: .nextTime) ?? time.addingTimeInterval(86_400)
    }

    func arm(at time: Date) {
        arm(after: Self.nextOccurrence(of: time).timeIntervalSinceNow)
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
        AlarmController.disarm(reason: "手動重置")
        NotificationBurst.clear()
        refresh()
    }

    // MARK: 解鎖

    func beginUnlock() {
        guard !showQRScanner, !scanning else { return }
        if state.phase.missionPending { startScanBuffer() }
        switch state.unlockMethod {
        case .qr: showQRScanner = true
        case .nfc: startScan()
        }
    }

    /// 掃描一打開就先取消全部、緩衝 bufferSeconds，免得響鈴畫面蓋住相機
    private func startScanBuffer() {
        let seconds = state.bufferSeconds
        state = Store.update { $0.phase = .buffer }
        Log.write("📷 開始掃描，緩衝 \(seconds)s")
        Task {
            await AlarmController.scheduleSequence(startIn: TimeInterval(seconds), reason: "掃描緩衝 \(seconds)s 到了")
            refresh()
        }
    }

    /// 關掉相機（或 NFC 失敗）卻沒驗證成功 → 幾秒後恢復響鈴
    func scannerDismissed() {
        let latest = Store.load()
        guard latest.phase.missionPending else { return }
        state = Store.update { $0.phase = .armed }
        Log.write("📷 關掉掃描但沒成功 → \(latest.rearmSeconds)s 後恢復響鈴")
        Task {
            await AlarmController.scheduleSequence(startIn: TimeInterval(latest.rearmSeconds), reason: "掃描沒成功")
            refresh()
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
        AlarmController.disarm(reason: "\(source) 驗證成功")
        NotificationBurst.clear()
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
            // App 資料遺失（刪掉重裝、換憑證）時，掃已經印好的那張就能恢復
            if payload.hasPrefix("WAKEUP-") {
                state = Store.update { $0.qrToken = payload }
                Log.write("♻️ 從紙本 QR Code 恢復")
            } else {
                Log.write("❌ 這不是起床 App 的 QR Code")
            }
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
            scannerDismissed()
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
                scannerDismissed()
            }
        }
        refresh()
    }

    func removeTag(_ uid: String) {
        state = Store.update { $0.nfcWhitelist.removeAll { $0 == uid } }
    }
}
