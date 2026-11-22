import Foundation

// MARK: - 天氣：有授權碼用中央氣象署鄉鎮預報，否則（或失敗時）用 Open-Meteo。結果存在 App Group 的 weather.json

/// 穿衣體質：加到體感溫度上再查表。怕熱的人覺得比較熱，所以 +2。
enum HeatTolerance: String, Codable, CaseIterable {
    case cold, normal, hot

    var title: String {
        switch self {
        case .cold: return "怕冷"
        case .normal: return "普通"
        case .hot: return "怕熱"
        }
    }

    var offset: Double {
        switch self {
        case .cold: return -2
        case .normal: return 0
        case .hot: return 2
        }
    }
}

struct WeatherHour: Codable {
    var time: Date
    var temp: Double
    var feels: Double
    var rainChance: Int   // %
    var rain: Double      // mm
    var code: Int         // WMO 天氣代碼
    var wind: Double      // km/h
}

struct WeatherReport: Codable {
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double
    var currentTemp: Double
    var currentFeels: Double
    var currentCode: Int
    var currentRain: Double
    var currentWind: Double
    var hours: [WeatherHour]
    var source: String? = nil   // 「中央氣象署」或「Open-Meteo」（舊快取沒有這欄）
    var place: String? = nil    // 例如「臺北市大安區」
}

/// WMO 天氣代碼 → SF Symbol 與中文
enum WeatherCode {
    static func describe(_ code: Int) -> (symbol: String, text: String) {
        switch code {
        case 0: return ("sun.max.fill", "晴")
        case 1: return ("sun.max.fill", "晴時多雲")
        case 2: return ("cloud.sun.fill", "多雲")
        case 3: return ("cloud.fill", "陰")
        case 45, 48: return ("cloud.fog.fill", "霧")
        case 51...57: return ("cloud.drizzle.fill", "毛毛雨")
        case 61, 66: return ("cloud.rain.fill", "小雨")
        case 63: return ("cloud.rain.fill", "雨")
        case 65, 67: return ("cloud.heavyrain.fill", "大雨")
        case 71...77, 85, 86: return ("snowflake", "雪")
        case 80, 81: return ("cloud.sun.rain.fill", "陣雨")
        case 82: return ("cloud.heavyrain.fill", "大陣雨")
        case 95...99: return ("cloud.bolt.rain.fill", "雷雨")
        default: return ("cloud.fill", "—")
        }
    }
}

// MARK: - 抓資料與快取

enum WeatherService {
    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("weather.json") }

    static func loadCached() -> WeatherReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WeatherReport.self, from: data)
    }

    private static func save(_ report: WeatherReport) {
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static let gate = WeatherGate()

    /// 用 state 裡存的位置抓一次並存起來。沒設定位置、正在抓、或離上次嘗試不到 minInterval 秒就跳過（回傳 nil）。
    @discardableResult
    static func refresh(reason: String, minInterval: TimeInterval = 60) async -> WeatherReport? {
        let state = Store.load()
        guard let lat = state.weatherLatitude, let lon = state.weatherLongitude else { return nil }
        guard await gate.begin(minInterval: minInterval) else { return nil }
        var result: WeatherReport?
        let key = state.cwaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                let report = try await CWAWeather.fetch(key: key, latitude: lat, longitude: lon)
                result = report
            } catch {
                Log.write("⚠️ 氣象署失敗（\(reason)），改用 Open-Meteo：\(CWAWeather.describe(error))")
            }
        }
        if result == nil {
            do {
                result = try await fetch(latitude: lat, longitude: lon)
            } catch {
                Log.write("⚠️ 天氣更新失敗（\(reason)）：\(error.localizedDescription)")
            }
        }
        if let report = result {
            save(report)
            Log.write("🌤 天氣更新（\(reason)，\(report.source ?? "Open-Meteo")\(report.place.map { " " + $0 } ?? "")）：\(Int(report.currentTemp.rounded()))° 體感 \(Int(report.currentFeels.rounded()))° \(WeatherCode.describe(report.currentCode).text)")
        }
        await gate.end()
        return result
    }

    static func fetch(latitude: Double, longitude: Double) async throws -> WeatherReport {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", latitude)),
            .init(name: "longitude", value: String(format: "%.2f", longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "2"),
        ]
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let h = r.hourly
        var hours: [WeatherHour] = []
        for i in h.time.indices {
            guard let temp = h.temperature_2m[safe: i] ?? nil else { continue }
            hours.append(WeatherHour(
                time: Date(timeIntervalSince1970: TimeInterval(h.time[i])),
                temp: temp,
                feels: (h.apparent_temperature[safe: i] ?? nil) ?? temp,
                rainChance: (h.precipitation_probability[safe: i] ?? nil) ?? 0,
                rain: (h.precipitation[safe: i] ?? nil) ?? 0,
                code: (h.weather_code[safe: i] ?? nil) ?? 0,
                wind: (h.wind_speed_10m[safe: i] ?? nil) ?? 0
            ))
        }
        let firstHour = hours.first
        let cur = r.current
        let temp = cur.temperature_2m ?? firstHour?.temp ?? 0
        return WeatherReport(
            fetchedAt: Date(),
            latitude: latitude,
            longitude: longitude,
            currentTemp: temp,
            currentFeels: cur.apparent_temperature ?? temp,
            currentCode: cur.weather_code ?? firstHour?.code ?? 0,
            currentRain: cur.precipitation ?? 0,
            currentWind: cur.wind_speed_10m ?? 0,
            hours: hours,
            source: "Open-Meteo"
        )
    }
}

/// 避免同時抓好幾次（上膛、鬧鐘前、掃碼成功可能撞在一起）
private actor WeatherGate {
    private var running = false
    private var lastAttempt = Date.distantPast

    func begin(minInterval: TimeInterval) -> Bool {
        guard !running, Date().timeIntervalSince(lastAttempt) >= minInterval else { return false }
        running = true
        lastAttempt = Date()
        return true
    }

    func end() { running = false }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let weather_code: Int?
        let precipitation: Double?
        let wind_speed_10m: Double?
    }
    struct Hourly: Decodable {
        let time: [Int]
        let temperature_2m: [Double?]
        let apparent_temperature: [Double?]
        let precipitation_probability: [Int?]
        let precipitation: [Double?]
        let weather_code: [Int?]
        let wind_speed_10m: [Double?]
    }
    let current: Current
    let hourly: Hourly
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - 穿衣與帶傘建議

struct WeatherAdvice {
    enum Umbrella { case none, folding, needed }

    let untilText: String      // 「到 22 點」
    let tempLow: Double
    let tempHigh: Double
    let feelsLow: Double
    let feelsHigh: Double
    let clothing: String       // 「短袖 + 薄外套」
    let umbrella: Umbrella
    let maxRainChance: Int
    let rainHours: String?     // 「14～17 點」
    let notes: [String]

    /// 看「現在到 untilHour 點」這段時間；已經過了 untilHour 就看接下來 6 小時
    static func make(report: WeatherReport, now: Date = Date(), untilHour: Int, tolerance: HeatTolerance) -> WeatherAdvice? {
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: now)?.start ?? now
        var end = cal.date(bySettingHour: untilHour, minute: 0, second: 0, of: now) ?? now
        var untilText = "到 \(untilHour) 點"
        if end <= hourStart {
            end = hourStart.addingTimeInterval(6 * 3600)
            untilText = "接下來 6 小時"
        }
        let window = report.hours.filter { $0.time >= hourStart && $0.time <= end }
        guard !window.isEmpty else { return nil }

        let temps = window.map(\.temp)
        let feels = window.map(\.feels)
        let feelsLow = feels.min()!, feelsHigh = feels.max()!
        let adjLow = feelsLow + tolerance.offset
        let adjHigh = feelsHigh + tolerance.offset

        // 內層看最熱的時候，外套看最冷的時候
        let base: String
        switch adjHigh {
        case 24...: base = "短袖"
        case 18..<24: base = "長袖"
        case 12..<18: base = "長袖＋內搭"
        default: base = "發熱衣＋長袖"
        }
        let outer: String?
        switch adjLow {
        case 24...: outer = nil
        case 20..<24: outer = "薄外套"
        case 16..<20: outer = "外套（夾克、帽 T）"
        case 12..<16: outer = "厚外套"
        default: outer = "羽絨衣或大衣"
        }
        let clothing = outer.map { "\(base) ＋ \($0)" } ?? "\(base)，不用外套"

        var notes: [String] = []
        if outer != nil && feelsHigh - feelsLow >= 8 {
            notes.append("溫差大：早晚涼、中午熱，穿好脫的")
        }
        if outer == nil && adjHigh >= 26 && tolerance != .hot {
            notes.append("教室冷氣強的話，包包放件薄外套")
        }
        let maxWind = window.map(\.wind).max() ?? 0
        if maxWind >= 40 {
            notes.append("風很大，傘可能撐不住")
        } else if maxWind >= 30 {
            notes.append("風大，外套選防風的")
        }
        if report.currentRain > 0 && report.fetchedAt.timeIntervalSince(now) > -3600 {
            notes.insert("現在正在下雨", at: 0)
        }

        let maxChance = window.map(\.rainChance).max() ?? 0
        let totalRain = window.map(\.rain).reduce(0, +)
        let umbrella: Umbrella
        let threshold: Int
        if maxChance >= 50 || totalRain >= 1 {
            umbrella = .needed; threshold = 50
        } else if maxChance >= 30 || totalRain >= 0.2 {
            umbrella = .folding; threshold = 30
        } else {
            umbrella = .none; threshold = 101
        }
        let rainy = window.filter { $0.rainChance >= threshold || $0.rain >= 0.3 }
        var rainHours: String?
        if let first = rainy.first, let last = rainy.last {
            let a = cal.component(.hour, from: first.time)
            let b = cal.component(.hour, from: last.time) + 1
            rainHours = "\(a)～\(b) 點"
        }

        return WeatherAdvice(untilText: untilText, tempLow: temps.min()!, tempHigh: temps.max()!,
                             feelsLow: feelsLow, feelsHigh: feelsHigh, clothing: clothing,
                             umbrella: umbrella, maxRainChance: maxChance, rainHours: rainHours, notes: notes)
    }
}
