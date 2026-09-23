import Foundation

/// api.ani.zip の対応表（AniList ID → AniDB / TVDB / IMDb / TMDB、各話の AniDB エピソード ID など）。
/// 拡張機能のクエリ（anidbAid / anidbEid / tvdbAid …）を埋めるのに使う。
actor AniZipClient {
    static let shared = AniZipClient()

    private var cache: [String: (date: Date, value: JSONValue)] = [:]
    private let ttl: TimeInterval = 6 * 60 * 60

    func mappings(anilistID: Int, malID: Int?) async -> JSONValue? {
        let key = "ani-\(anilistID)"
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < ttl { return hit.value }
        var result = await fetch("https://api.ani.zip/mappings?anilist_id=\(anilistID)")
        if result == nil, let malID {
            qlog(.debug, "anizip", "anilist_id=\(anilistID) で見つからないため mal_id=\(malID) で再試行")
            result = await fetch("https://api.ani.zip/mappings?mal_id=\(malID)")
        }
        if let result { cache[key] = (Date(), result) }
        return result
    }

    private func fetch(_ urlString: String) async -> JSONValue? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                qlog(status == 404 ? .debug : .warn, "anizip", "HTTP \(status): \(urlString)")
                return nil
            }
            let json = JSONValue(any: try JSONSerialization.jsonObject(with: data))
            let anidb = json["mappings"]?["anidb_id"]?.stringValue ?? "-"
            let episodes = json["episodes"]?.objectValue?.count ?? 0
            qlog(.info, "anizip", "対応表を取得: anidb=\(anidb), 話数=\(episodes)")
            return json
        } catch {
            qlog(.warn, "anizip", "取得失敗: \(error.localizedDescription)")
            return nil
        }
    }
}
