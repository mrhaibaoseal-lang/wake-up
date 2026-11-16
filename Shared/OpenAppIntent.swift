import AppIntents

/// 控制中心「起床」按鈕用：只打開 App，不能停止、解除或延後鬧鐘。
/// 放在 Shared，App 與 Widget 兩個 target 都編得到（控制中心按鈕需要 App 端也有這個 intent）。
struct OpenWakeAppIntent: AppIntent {
    static var title: LocalizedStringResource = "打開起床"
    static var description = IntentDescription("打開起床 App")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
