import Foundation
import WidgetKit

// MARK: - 讀取自己的 embedded.mobileprovision（到期日、App Group 清單）

enum ProvisioningInfo {
    static let plist: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: slice, format: nil)) as? [String: Any]
    }()

    static var expirationDate: Date? { plist?["ExpirationDate"] as? Date }

    static var appGroups: [String] {
        let ent = plist?["Entitlements"] as? [String: Any]
        return ent?["com.apple.security.application-groups"] as? [String] ?? []
    }
}

// MARK: - App Group：不寫死，啟動時找第一個真的能讀寫的

enum AppGroup {
    /// 來自 Flarestore profile 的群組，當作 embedded.mobileprovision 讀不到時的備援
    static let fallback = [
        "group.81c139ae9a27a7f8.1",
        "group.81c139ae9a27a7f8.2",
        "group.81c139ae9a27a7f8.3",
        "group.81c139ae9a27a7f8.4",
        "group.81c139ae9a27a7f8.5",
    ]

    static let resolved: (id: String, url: URL)? = {
        var candidates = ProvisioningInfo.appGroups.sorted()
        for g in fallback where !candidates.contains(g) { candidates.append(g) }
        for id in candidates {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { continue }
            let probe = url.appendingPathComponent(".probe")
            if (try? Data("ok".utf8).write(to: probe, options: .atomic)) != nil {
                return (id, url)
            }
        }
        return nil
    }()

    static var containerURL: URL {
        if let url = resolved?.url { return url }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 記錄（App 與 Widget 共用同一個檔案）

enum Log {
    private static let queue = DispatchQueue(label: "wakeup.log")
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("poc.log") }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var processTag: String {
        Bundle.main.bundlePath.hasSuffix(".appex") ? "widget" : "app"
    }

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))][\(processTag)] \(message)\n"
        let data = Data(line.utf8)
        queue.sync {
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        print(line, terminator: "")
    }

    static func readAll() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    static func lastLine() -> String {
        readAll().split(separator: "\n").last.map(String.init) ?? ""
    }

    static func clear() {
        queue.sync { _ = try? FileManager.default.removeItem(at: fileURL) }
    }
}

// MARK: - 狀態（持久化在 App Group，App 被殺後可還原）

enum Phase: String, Codable {
    case idle      // 未上膛
    case armed     // 已上膛 / 響鈴中，任務未完成
    case buffer    // 按了「去掃描」，緩衝倒數中
    case verified  // NFC 驗證成功

    var title: String {
        switch self {
        case .idle: return "未上膛"
        case .armed: return "已上膛／響鈴中"
        case .buffer: return "緩衝中（去掃描）"
        case .verified: return "已驗證 ✅"
        }
    }

    /// 任務還沒完成：按停止要重排
    var missionPending: Bool { self == .armed || self == .buffer }
}

enum UnlockMethod: String, Codable {
    case qr
    case nfc
}

struct PoCState: Codable {
    var phase: Phase = .idle
    var rearmCount: Int = 0
    var rearmSeconds: Int = 15
    var bufferSeconds: Int = 45
    var stopRearmEnabled: Bool = true
    var callStopInIntent: Bool = true
    var pendingScan: Bool = false
    var nfcWhitelist: [String] = []
    var unlockMethod: UnlockMethod = .qr
    var qrToken: String? = nil
    var lastUpdated: Date = Date()

    init() {}

    // 新增欄位時舊資料仍可讀（缺的欄位用預設值），避免白名單被清掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PoCState()
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? d.phase
        rearmCount = try c.decodeIfPresent(Int.self, forKey: .rearmCount) ?? d.rearmCount
        rearmSeconds = try c.decodeIfPresent(Int.self, forKey: .rearmSeconds) ?? d.rearmSeconds
        bufferSeconds = try c.decodeIfPresent(Int.self, forKey: .bufferSeconds) ?? d.bufferSeconds
        stopRearmEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopRearmEnabled) ?? d.stopRearmEnabled
        callStopInIntent = try c.decodeIfPresent(Bool.self, forKey: .callStopInIntent) ?? d.callStopInIntent
        pendingScan = try c.decodeIfPresent(Bool.self, forKey: .pendingScan) ?? d.pendingScan
        nfcWhitelist = try c.decodeIfPresent([String].self, forKey: .nfcWhitelist) ?? d.nfcWhitelist
        unlockMethod = try c.decodeIfPresent(UnlockMethod.self, forKey: .unlockMethod) ?? d.unlockMethod
        qrToken = try c.decodeIfPresent(String.self, forKey: .qrToken)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? d.lastUpdated
    }
}

enum Store {
    private static let queue = DispatchQueue(label: "wakeup.store")
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("state.json") }

    static func load() -> PoCState {
        queue.sync { loadUnlocked() }
    }

    private static func loadUnlocked() -> PoCState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PoCState.self, from: data)
        else { return PoCState() }
        return state
    }

    @discardableResult
    static func update(_ body: (inout PoCState) -> Void) -> PoCState {
        let state: PoCState = queue.sync {
            var s = loadUnlocked()
            body(&s)
            s.lastUpdated = Date()
            if let data = try? JSONEncoder().encode(s) {
                try? data.write(to: fileURL, options: .atomic)
            }
            return s
        }
        WidgetCenter.shared.reloadAllTimelines()
        return state
    }
}

extension UUID {
    var short: String { String(uuidString.prefix(8)) }
}
