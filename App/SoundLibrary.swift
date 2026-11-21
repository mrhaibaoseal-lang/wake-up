import AVFoundation
import Observation

/// 鬧鐘聲音：內建音檔、使用者匯入的音檔（檔案 App 或網址下載）、試聽。
///
/// 匯入的檔案一律轉成 44.1 kHz 單聲道 16-bit CAF、截到 29 秒以內，放在 App 的 Library/Sounds：
/// AlarmKit 的 `.named()` 只找 App bundle 與 Library/Sounds，而且要 30 秒以內；
/// App 警報聲（KeepAlive）也要求 44.1 kHz 單聲道。
@MainActor
@Observable
final class SoundLibrary {
    static let shared = SoundLibrary()

    struct BuiltIn: Identifiable {
        let file: String
        let title: String
        let detail: String
        var id: String { file }
    }

    struct Custom: Codable, Identifiable, Hashable {
        let file: String
        var name: String
        var id: String { file }
    }

    static let builtIns: [BuiltIn] = [
        .init(file: "wake_scream.wav", title: "極限尖叫",
              detail: "耳朵最敏感的 2.5～4 kHz 高頻顫音＋雜訊爆裂，幾乎沒有空檔，每 7 秒加速"),
        .init(file: "wake_chaos.wav", title: "隨機轟炸",
              detail: "每 0.06～0.25 秒隨機換一種聲音，沒有節奏可以習慣"),
        .init(file: "wake_klaxon.wav", title: "防空警報",
              detail: "低音鋸齒波上滑＋高頻嗶聲，隔著棉被也穿得透"),
        .init(file: "wake_alarm.wav", title: "舊版警笛",
              detail: "原本的上揚警笛＋不和諧和弦"),
    ]

    nonisolated static let maxSeconds = 29.0

    private(set) var customs: [Custom] = []
    /// 正在試聽的聲音（nil = 沒在播）
    private(set) var previewing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    private init() { customs = Self.loadIndex() }

    // MARK: - 路徑

    nonisolated static var soundsDirectory: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_sounds.json")
    }

    /// 這個選擇實際要播的檔案（系統預設或檔案不見時用最刺耳的內建音，給 App 警報聲用）
    nonisolated static func fileURL(for choice: String) -> URL? {
        let file = choice == AlarmSound.systemDefault ? AlarmSound.defaultChoice : choice
        if let url = Bundle.main.url(forResource: file, withExtension: nil) { return url }
        let custom = soundsDirectory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: custom.path) { return custom }
        return Bundle.main.url(forResource: AlarmSound.defaultChoice, withExtension: nil)
    }

    func title(for choice: String) -> String {
        if choice == AlarmSound.systemDefault { return "系統預設鈴聲" }
        if let b = Self.builtIns.first(where: { $0.file == choice }) { return b.title }
        if let c = customs.first(where: { $0.file == choice }) { return c.name }
        return "（檔案遺失）"
    }

    // MARK: - 匯入

    enum ImportError: LocalizedError {
        case empty, unsupported, http(Int), notAudio

        var errorDescription: String? {
            switch self {
            case .empty: return "檔案裡沒有聲音"
            case .unsupported: return "這個格式轉不了，請換 mp3、m4a 或 wav"
            case .http(let code): return "下載失敗（HTTP \(code)）"
            case .notAudio: return "這個網址不是音檔。要貼「直接下載音檔」的網址（結尾通常是 .mp3、.m4a、.wav），不能是 YouTube 或網頁"
            }
        }
    }

    /// 從檔案 App 選的檔案匯入
    func importFile(at source: URL, boost: Bool) async throws -> Custom {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.deletingPathExtension().lastPathComponent
        return try await convertAndSave(source, name: name, boost: boost)
    }

    /// 從網址下載匯入
    func importURL(_ text: String, boost: Bool) async throws -> Custom {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { throw ImportError.notAudio }
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.http(http.statusCode)
        }
        if let mime = response.mimeType?.lowercased(), mime.hasPrefix("text/") {
            throw ImportError.notAudio
        }
        // AVAudioFile 靠副檔名判斷格式比較穩，搬到有正確副檔名的暫存檔
        let suggested = response.suggestedFilename ?? url.lastPathComponent
        var ext = (suggested as NSString).pathExtension
        if ext.isEmpty { ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temp, to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let name = (suggested as NSString).deletingPathExtension
        return try await convertAndSave(local, name: name.isEmpty ? "網路下載" : name, boost: boost)
    }

    private func convertAndSave(_ source: URL, name: String, boost: Bool) async throws -> Custom {
        let file = "custom_\(Int(Date().timeIntervalSince1970)).caf"
        let destination = Self.soundsDirectory.appendingPathComponent(file)
        let seconds = try await Task.detached(priority: .userInitiated) {
            try Self.convert(source, to: destination, boost: boost)
        }.value
        let custom = Custom(file: file, name: name)
        customs.append(custom)
        saveIndex()
        Log.write("🎵 匯入鈴聲「\(name)」→ \(file)（\(String(format: "%.1f", seconds)) 秒\(boost ? "，已加強音量" : "")）")
        return custom
    }

    /// 轉成 44.1 kHz 單聲道、截到 29 秒、拉到最大音量（boost 時再壓縮讓平均音量更大）。回傳秒數
    nonisolated private static func convert(_ source: URL, to destination: URL, boost: Bool) throws -> Double {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw ImportError.unsupported }
        let inFormat = input.processingFormat
        let frames = AVAudioFrameCount(min(Double(input.length), maxSeconds * inFormat.sampleRate))
        guard frames > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
        else { throw ImportError.empty }
        try input.read(into: inBuffer, frameCount: frames)

        let target = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: target) else { throw ImportError.unsupported }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * target.sampleRate / inFormat.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw ImportError.unsupported }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error || out.frameLength == 0 { throw conversionError ?? ImportError.unsupported }

        // 正規化（＋軟削波壓縮），頭尾 5 ms 淡入淡出避免循環時喀一聲
        let data = out.floatChannelData![0]
        let n = Int(out.frameLength)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(data[i])) }
        guard peak > 0.0001 else { throw ImportError.empty }
        let drive: Float = boost ? 3 : 1
        let norm = tanhf(drive)
        let fade = min(220, n / 2)
        for i in 0..<n {
            var x = data[i] / peak
            if boost { x = tanhf(drive * x) / norm }
            if i < fade { x *= Float(i) / Float(fade) }
            if i >= n - fade { x *= Float(n - 1 - i) / Float(fade) }
            data[i] = 0.98 * x
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: out)
        return Double(n) / target.sampleRate
    }

    func rename(_ custom: Custom, to name: String) {
        guard let i = customs.firstIndex(of: custom) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customs[i].name = trimmed
        saveIndex()
    }

    func delete(_ custom: Custom) {
        if previewing == custom.file { stopPreview() }
        try? FileManager.default.removeItem(at: Self.soundsDirectory.appendingPathComponent(custom.file))
        customs.removeAll { $0.file == custom.file }
        saveIndex()
        Log.write("🗑️ 刪除鈴聲「\(custom.name)」")
    }

    private static func loadIndex() -> [Custom] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Custom].self, from: data) else { return [] }
        // 只留檔案還在的
        return list.filter { FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent($0.file).path) }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(customs) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: - 試聽

    /// 再按一次同一個就停止；最多播 10 秒
    func togglePreview(_ choice: String) {
        if previewing == choice {
            stopPreview()
            return
        }
        stopPreview()
        guard let url = Self.fileURL(for: choice) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)   // 靜音鍵開著也聽得到
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            previewing = choice
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.stopPreview()
            }
        } catch {
            Log.write("⚠️ 試聽失敗：\(error.localizedDescription)")
        }
    }

    func stopPreview() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        guard previewing != nil else { return }
        previewing = nil
        // 上膛中保活在用音訊，不要把 session 關掉
        if !KeepAlive.shared.running {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
