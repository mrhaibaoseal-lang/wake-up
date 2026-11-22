import AVFoundation

/// 解鎖成功後用內建中文（台灣）語音唸一段很短的天氣。
/// 用 .playback：靜音鍵開著也聽得到；引導使用模式不影響聲音。
@MainActor
final class WakeSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = WakeSpeech()
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 例：「早安，現在 18 度，最高 24 度。穿長袖加薄外套。下午 14 點到 17 點會下雨，記得帶傘。」
    static func text(report: WeatherReport?, untilHour: Int, tolerance: HeatTolerance) -> String {
        // 太舊（超過 12 小時）的資料不唸
        guard let report, report.fetchedAt.timeIntervalSinceNow > -12 * 3600 else {
            return "早安。天氣資料還沒抓到。"
        }
        var s = "早安，現在\(Int(report.currentTemp.rounded()))度"
        guard let advice = WeatherAdvice.make(report: report, untilHour: untilHour, tolerance: tolerance) else {
            return s + "。"
        }
        s += "，最高\(Int(advice.tempHigh.rounded()))度。"
        // 「長袖 ＋ 外套（夾克、帽 T）」→「長袖加外套」
        var clothing = advice.clothing.replacingOccurrences(of: " ＋ ", with: "加")
        if let paren = clothing.firstIndex(of: "（") { clothing = String(clothing[..<paren]) }
        s += "穿\(clothing)。"
        let hours = advice.rainHours?
            .replacingOccurrences(of: " 點", with: "點")
            .replacingOccurrences(of: "～", with: "點到")
        switch advice.umbrella {
        case .needed: s += "\(hours ?? "今天")會下雨，記得帶傘。"
        case .folding: s += "\(hours ?? "今天")可能下雨，帶把折疊傘。"
        case .none: break
        }
        return s
    }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        Log.write("🗣 語音播報：\(text)")
    }

    /// 中文（台灣）裡品質最好的聲音（有下載「加強版」就會用到）
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-TW" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "zh-TW")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // 鬧鐘又上膛時保活會自己重新設定 audio session，這裡只在沒在講話時放掉
            guard !self.synth.isSpeaking, !KeepAlive.shared.running else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
