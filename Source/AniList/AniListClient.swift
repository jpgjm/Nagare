import Foundation

/// AniList GraphQL（ログインなし）。初版では作品の検索と指定にだけ使う。
/// ログイン・リスト管理・進捗記録は次の段階で入れる。
actor AniListClient {
    static let shared = AniListClient()

    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private var cache: [Int: AniMedia] = [:]

    /// 検索・詳細で共通に取る項目。拡張機能が `media` から参照しうる項目を多めに取る。
    private static let mediaFields = """
    id idMal type format status episodes duration season seasonYear averageScore isAdult countryOfOrigin
    title { romaji english native userPreferred }
    synonyms genres bannerImage
    description(asHtml: false)
    coverImage { extraLarge large medium color }
    startDate { year month day }
    endDate { year month day }
    nextAiringEpisode { episode airingAt }
    relations { edges { relationType node { id type format } } }
    """

    func search(_ text: String, includeAdult: Bool) async throws -> [AniMedia] {
        let adultFilter = includeAdult ? "" : ", isAdult: false"
        let query = """
        query ($search: String, $page: Int) {
          Page(page: $page, perPage: 30) {
            media(search: $search, type: ANIME, sort: SEARCH_MATCH\(adultFilter)) { \(Self.mediaFields) }
          }
        }
        """
        let json = try await request(query: query, variables: ["search": text, "page": 1])
        let list = json["data"]?["Page"]?["media"]?.arrayValue ?? []
        let media = list.compactMap(AniMedia.init(raw:))
        for m in media { cache[m.id] = m }
        qlog(.info, "anilist", "検索「\(text)」: \(media.count) 件")
        return media
    }

    /// 詳細（放送スケジュール付き）。拡張に渡す `media` はこちらを使う。
    func media(id: Int) async throws -> AniMedia {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) {
            \(Self.mediaFields)
            airingSchedule(notYetAired: false, perPage: 50) { nodes { episode airingAt } }
          }
        }
        """
        let json = try await request(query: query, variables: ["id": id])
        guard let raw = json["data"]?["Media"], let media = AniMedia(raw: raw) else {
            throw AniListError.notFound(id)
        }
        cache[id] = media
        qlog(.debug, "anilist", "詳細取得: \(id) \(media.displayTitle)")
        return media
    }

    private func request(query: String, variables: [String: Any]) async throws -> JSONValue {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let json = JSONValue(any: try? JSONSerialization.jsonObject(with: data))

        if status == 429 {
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "?"
            qlog(.warn, "anilist", "レート制限（429）。Retry-After=\(retry)")
            throw AniListError.rateLimited
        }
        if let errors = json["errors"]?.arrayValue, !errors.isEmpty {
            let message = errors.compactMap { $0["message"]?.stringValue }.joined(separator: " / ")
            qlog(.error, "anilist", "GraphQL エラー（HTTP \(status), \(elapsed)ms）: \(message)")
            throw AniListError.graphQL(message)
        }
        guard (200..<300).contains(status) else {
            qlog(.error, "anilist", "HTTP \(status)（\(elapsed)ms）")
            throw AniListError.http(status)
        }
        qlog(.debug, "anilist", "HTTP \(status)（\(elapsed)ms, \(data.count) bytes）")
        return json
    }
}

enum AniListError: LocalizedError {
    case http(Int)
    case graphQL(String)
    case rateLimited
    case notFound(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "AniList が HTTP \(code) を返しました"
        case .graphQL(let message): return "AniList のエラー: \(message)"
        case .rateLimited: return "AniList のレート制限に達しました。少し待ってから再試行してください"
        case .notFound(let id): return "作品 \(id) が見つかりません"
        }
    }
}
