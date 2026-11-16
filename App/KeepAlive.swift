import AVFoundation

/// 上膛期間在背景播放無聲音軌，讓 App 整晚保持執行；
/// 鬧鐘時間到之後，由 App 自己播警報聲（實體按鍵只能停掉 AlarmKit 的聲音，停不掉這個）。
/// 失敗時只是退回 AlarmKit 本身的行為（不會讓鬧鐘不響）。
final class KeepAlive {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    private let siren = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var configured = false
    private var wanted = false
    private(set) var sirenOn = false
    private var lastFailureLog = Date.distantPast

    var running: Bool { wanted && engine.isRunning }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("⚠️ 保活：音訊服務重設")
            self?.configured = false
            self?.ensureRunning()
        }
    }

    func start() {
        if !wanted { Log.write("🔈 保活啟動") }
        wanted = true
        ensureRunning()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        sirenOn = false
        siren.stop()
        silence.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.write("🔇 保活停止")
    }

    /// 每幾秒呼叫一次：引擎被中斷就重新啟動
    func ensureRunning() {
        guard wanted, !engine.isRunning || !silence.isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if !configured {
                engine.attach(silence)
                engine.attach(siren)
                engine.connect(silence, to: engine.mainMixerNode, format: format)
                engine.connect(siren, to: engine.mainMixerNode, format: format)
                configured = true
            }
            if !engine.isRunning { try engine.start() }
            silence.stop()
            silence.scheduleBuffer(makeBuffer(siren: false), at: nil, options: .loops)
            silence.play()
            if sirenOn { playSiren() }
            Log.write("🔈 音訊引擎已（重新）啟動")
        } catch {
            if Date().timeIntervalSince(lastFailureLog) > 20 {
                lastFailureLog = Date()
                Log.write("❌ 音訊引擎啟動失敗：\(error.localizedDescription)")
            }
        }
    }

    func setSiren(_ on: Bool) {
        guard on != sirenOn else { return }
        sirenOn = on
        if on {
            Log.write("🚨 App 警報聲開始")
            if engine.isRunning { playSiren() }
        } else {
            Log.write("🚨 App 警報聲停止")
            siren.stop()
        }
    }

    private lazy var sirenBuffer: AVAudioPCMBuffer = loadSirenFile() ?? makeBuffer(siren: true)

    private func playSiren() {
        siren.stop()
        siren.scheduleBuffer(sirenBuffer, at: nil, options: .loops)
        siren.play()
    }

    /// 跟系統鬧鐘用同一個警報音檔；讀不到就用程式產生的方波
    private func loadSirenFile() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: "wake_alarm", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == format.sampleRate,
              file.processingFormat.channelCount == format.channelCount,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else {
            Log.write("⚠️ 讀不到警報音檔，改用內建方波")
            return nil
        }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            Log.write("⚠️ 警報音檔讀取失敗：\(error.localizedDescription)")
            return nil
        }
    }

    /// 1 秒的緩衝：無聲，或 1000Hz / 1500Hz 交替的方波警報
    private func makeBuffer(siren: Bool) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            if siren {
                let t = Double(i) / format.sampleRate
                let freq = t < 0.5 ? 1000.0 : 1500.0
                data[i] = sin(2 * .pi * freq * t) >= 0 ? 0.9 : -0.9
            } else {
                data[i] = 0
            }
        }
        return buffer
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.write("⚠️ 音訊被中斷（鬧鐘、來電或其他 App），立刻嘗試恢復")
            ensureRunning()
        case .ended:
            Log.write("音訊中斷結束")
            ensureRunning()
        @unknown default:
            break
        }
    }
}
