import AVFoundation

/// 上膛期間在背景播放無聲音軌，讓 App 整晚保持執行，才能「刷新」被靜音的鬧鐘。
/// 失敗時只是退回 AlarmKit 本身的行為（不會讓鬧鐘不響）。
final class KeepAlive {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var configured = false
    private(set) var running = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("⚠️ 保活：音訊服務重設，重新啟動")
            guard let self, self.running else { return }
            self.running = false
            self.configured = false
            self.start()
        }
    }

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            if !configured {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                configured = true
            }
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            if let data = buffer.floatChannelData {
                data[0].update(repeating: 0, count: Int(frames))
            }
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
            Log.write("🔈 保活啟動")
        } catch {
            Log.write("❌ 保活啟動失敗：\(error)")
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
        Log.write("🔇 保活停止")
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.write("⚠️ 保活被中斷（來電、其他 App 或鬧鐘）")
        case .ended:
            Log.write("保活中斷結束，嘗試恢復")
            guard running else { return }
            running = false
            start()
        @unknown default:
            break
        }
    }
}
