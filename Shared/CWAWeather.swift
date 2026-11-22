import Foundation

// MARK: - 中央氣象署開放資料：鄉鎮未來 3 天預報（F-D0047-001～085 每縣市一份）
//
// 實測回傳格式（2026-11）：
// records.Locations[0].Location[] = { LocationName: "大安區", Latitude, Longitude, WeatherElement[] }
// 溫度、體感溫度：每小時一筆 { DataTime, ElementValue: [{ Temperature / ApparentTemperature }] }
// 風速：每 3 小時一筆 { DataTime, ElementValue: [{ WindSpeed (m/s), BeaufortScale }] }
// 3小時降雨機率、天氣現象：區間 { StartTime, EndTime, ElementValue: [{ ProbabilityOfPrecipitation } / { Weather, WeatherCode }] }
// 授權碼錯誤回 HTTP 401。授權碼只存在手機的 state 裡，不能進 repo、不能寫進 log。

enum CWAWeather {
    enum CWAError: LocalizedError {
        case badKey
        case http(Int)
        case noTown
        case noData

        var errorDescription: String? {
            switch self {
            case .badKey: return "授權碼不對（401）"
            case .http(let code): return "伺服器回應 \(code)"
            case .noTown: return "找不到最近的鄉鎮"
            case .noData: return "資料是空的"
            }
        }
    }

    /// 只給 log 用的錯誤描述（不含網址，避免把授權碼寫進記錄）
    static func describe(_ error: Error) -> String {
        if let e = error as? CWAError { return e.errorDescription ?? "未知錯誤" }
        if let e = error as? URLError { return "網路錯誤 \(e.code.rawValue)" }
        if error is DecodingError { return "資料格式看不懂" }
        return "未知錯誤"
    }

    /// 22 個縣市的「未來 3 天鄉鎮預報」資料集
    static let datasets: [String] = stride(from: 1, through: 85, by: 4).map { String(format: "F-D0047-%03d", $0) }

    private static let base = "https://opendata.cwa.gov.tw/api/v1/rest/datastore/"

    static func fetch(key: String, latitude: Double, longitude: Double) async throws -> WeatherReport {
        var state = Store.load()
        if state.cwaDataset == nil || state.cwaTown == nil {
            let found = try await resolveTown(key: key, latitude: latitude, longitude: longitude)
            state = Store.update {
                $0.cwaDataset = found.dataset
                $0.cwaCounty = found.county
                $0.cwaTown = found.town
            }
            Log.write("📍 氣象署鄉鎮：\(found.county)\(found.town)")
        }
        guard let dataset = state.cwaDataset, let town = state.cwaTown else { throw CWAError.noTown }

        let response = try await get(dataset, key: key, extra: [
            .init(name: "LocationName", value: town),
            .init(name: "ElementName", value: "溫度,體感溫度,3小時降雨機率,天氣現象,風速"),
        ])
        guard let loc = response.records.Locations.first?.Location.first else { throw CWAError.noData }
        return try makeReport(loc, county: state.cwaCounty ?? "", latitude: latitude, longitude: longitude)
    }

    // MARK: 依座標找最近的鄉鎮（只在設定位置後第一次抓時做，5 次請求）

    private static func resolveTown(key: String, latitude: Double, longitude: Double) async throws -> (dataset: String, county: String, town: String) {
        // 只要座標，時間範圍縮到 3 小時讓回應變小
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy-MM-dd'T'HH:00:00"
        let now = Date()
        var best: (dist: Double, dataset: String, county: String, town: String)?
        // F-D0047-093 一次最多接受 5 個資料集
        for start in stride(from: 0, to: datasets.count, by: 5) {
            let ids = datasets[start..<min(start + 5, datasets.count)].joined(separator: ",")
            let r = try await get("F-D0047-093", key: key, extra: [
                .init(name: "locationId", value: ids),
                .init(name: "ElementName", value: "溫度"),
                .init(name: "timeFrom", value: f.string(from: now)),
                .init(name: "timeTo", value: f.string(from: now.addingTimeInterval(3 * 3600))),
            ])
            for county in r.records.Locations {
                for town in county.Location {
                    guard let la = Double(town.Latitude ?? ""), let lo = Double(town.Longitude ?? "") else { continue }
                    let dx = (lo - longitude) * cos(latitude * .pi / 180)
                    let dy = la - latitude
                    let d = dx * dx + dy * dy
                    if best == nil || d < best!.dist {
                        let id = county.Dataid ?? ""
                        best = (d, id.hasPrefix("F-") ? id : "F-" + id, county.LocationsName ?? "", town.LocationName)
                    }
                }
            }
        }
        guard let b = best, datasets.contains(b.dataset) else { throw CWAError.noTown }
        return (b.dataset, b.county, b.town)
    }

    // MARK: 網路

    private static func get(_ dataset: String, key: String, extra: [URLQueryItem]) async throws -> CWAResponse {
        var c = URLComponents(string: base + dataset)!
        c.queryItems = [.init(name: "Authorization", value: key), .init(name: "format", value: "JSON")] + extra
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 401 ? CWAError.badKey : CWAError.http(http.statusCode)
        }
        return try JSONDecoder().decode(CWAResponse.self, from: data)
    }

    // MARK: 轉成 WeatherReport

    private static func makeReport(_ loc: CWAResponse.Town, county: String, latitude: Double, longitude: Double) throws -> WeatherReport {
        let iso = ISO8601DateFormatter()
        func element(_ name: String) -> [CWAResponse.TimeEntry] {
            loc.WeatherElement.first { $0.ElementName == name }?.Time ?? []
        }
        func points(_ name: String, _ field: String) -> [(Date, Double)] {
            element(name).compactMap { t in
                guard let s = t.DataTime, let date = iso.date(from: s),
                      let v = Double(t.ElementValue.first?[field] ?? "") else { return nil }
                return (date, v)
            }.sorted { $0.0 < $1.0 }
        }
        func ranges(_ name: String, _ field: String) -> [(Date, Date, String)] {
            element(name).compactMap { t in
                guard let a = t.StartTime.flatMap(iso.date(from:)), let b = t.EndTime.flatMap(iso.date(from:)),
                      let v = t.ElementValue.first?[field] else { return nil }
                return (a, b, v)
            }
        }
        func inRange(_ list: [(Date, Date, String)], _ time: Date) -> String? {
            list.first { $0.0 <= time && time < $0.1 }?.2
        }

        let temps = points("溫度", "Temperature")
        guard !temps.isEmpty else { throw CWAError.noData }
        let feels = Dictionary(points("體感溫度", "ApparentTemperature"), uniquingKeysWith: { a, _ in a })
        let winds = points("風速", "WindSpeed")
        let pops = ranges("3小時降雨機率", "ProbabilityOfPrecipitation")
        let codes = ranges("天氣現象", "WeatherCode")

        let hours: [WeatherHour] = temps.map { time, temp in
            let wind = winds.last { $0.0 <= time }?.1 ?? winds.first?.1 ?? 0
            return WeatherHour(
                time: time,
                temp: temp,
                feels: feels[time] ?? temp,
                rainChance: Int(inRange(pops, time) ?? "") ?? 0,
                rain: 0,   // 氣象署鄉鎮預報沒有雨量，帶傘只看降雨機率
                code: wmo(Int(inRange(codes, time) ?? "") ?? 0),
                wind: wind * 3.6   // m/s → km/h
            )
        }
        let now = Date()
        let current = hours.last { $0.time <= now } ?? hours[0]
        return WeatherReport(
            fetchedAt: now,
            latitude: latitude,
            longitude: longitude,
            currentTemp: current.temp,
            currentFeels: current.feels,
            currentCode: current.code,
            currentRain: 0,
            currentWind: current.wind,
            hours: hours,
            source: "中央氣象署",
            place: county + loc.LocationName
        )
    }

    /// 氣象署天氣現象代碼 → 近似的 WMO 代碼（共用同一套圖示與文字）
    static func wmo(_ cwa: Int) -> Int {
        switch cwa {
        case 1: return 0                 // 晴
        case 2: return 1                 // 晴時多雲
        case 3, 4: return 2              // 多雲時晴、多雲
        case 5, 6, 7: return 3           // 多雲時陰、陰時多雲、陰
        case 8...14, 29...32, 38, 39: return 80   // 各種（短暫）陣雨／雨
        case 15...22, 33...36, 41: return 95      // 雷陣雨、午後雷陣雨
        case 23, 37, 42: return 71       // 雨雪、下雪
        case 24...28: return 45          // 有霧
        default: return 3
        }
    }
}

private struct CWAResponse: Decodable {
    struct TimeEntry: Decodable {
        let DataTime: String?
        let StartTime: String?
        let EndTime: String?
        let ElementValue: [[String: String]]
    }
    struct Element: Decodable {
        let ElementName: String
        let Time: [TimeEntry]
    }
    struct Town: Decodable {
        let LocationName: String
        let Latitude: String?
        let Longitude: String?
        let WeatherElement: [Element]
    }
    struct County: Decodable {
        let LocationsName: String?
        let Dataid: String?
        let Location: [Town]
    }
    struct Records: Decodable {
        let Locations: [County]
    }
    let records: Records
}
