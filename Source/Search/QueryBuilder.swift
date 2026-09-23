import Foundation

/// 拡張機能へ渡す TorrentQuery を組み立てる（Shiru の extensions/handler.js getTorrentResults 相当）。
enum QueryBuilder {
    struct Built {
        let options: [String: Any]
        let summary: String
    }

    static func build(media: AniMedia, episode: Int?, resolution: String) async -> Built {
        let aniDBMeta = await aniToAniDB(media)
        let mappings = aniDBMeta?["mappings"] ?? .object([:])
        let anidbAid = mappings["anidb_id"]
        let tvdbAid = mappings["thetvdb_id"]
        let imdbAid = mappings["imdb_id"]
        let mvdbAid = mappings["themoviedb_id"]

        var mappingsE: JSONValue = .object([:])
        if hasValue(anidbAid) || hasValue(tvdbAid), let aniDBMeta, let episode {
            mappingsE = aniToAniDBEpisode(media: media, episode: episode, meta: aniDBMeta) ?? .object([:])
        }
        let anidbEid: JSONValue? = hasValue(anidbAid) ? mappingsE["anidbEid"] : nil
        let tvdbEid: JSONValue? = hasValue(tvdbAid) ? mappingsE["tvdbId"] : nil

        var options: [String: Any] = [
            "anilistId": media.id,
            "episodeCount": media.maxEpisode,
            "media": media.raw.anyValue,
            "mappingsA": mappings.anyValue,
            "mappingsE": mappingsE.anyValue,
            "titles": media.searchTitles,
            "resolution": resolution,
            "exclusions": [String](), // mpv はほぼ全コーデックを再生できるので除外しない
            "isAndroid": false,
        ]
        func put(_ key: String, _ value: JSONValue?) {
            if let value, !value.isNull { options[key] = value.anyValue }
        }
        if let episode { options["episode"] = episode }
        put("season", mappingsE["seasonNumber"])
        put("beforeSeason", mappingsE["airedBeforeSeasonNumber"])
        put("afterSeason", mappingsE["airedAfterSeasonNumber"])
        put("absoluteEpisode", mappingsE["absoluteEpisodeNumber"] ?? mappingsE["episodeNumber"])
        put("beforeEpisode", mappingsE["airedBeforeEpisodeNumber"])
        put("afterEpisode", mappingsE["airedAfterEpisodeNumber"])
        put("anidbAid", anidbAid)
        put("anidbEid", anidbEid)
        put("tvdbAid", tvdbAid)
        put("tvdbEid", tvdbEid)
        put("imdbAid", imdbAid)
        put("mvdbAid", mvdbAid)

        let summary = "anilist=\(media.id) ep=\(episode.map(String.init) ?? "-") res=\(resolution) anidbAid=\(anidbAid?.stringValue ?? "-") anidbEid=\(anidbEid?.stringValue ?? "-") tvdbAid=\(tvdbAid?.stringValue ?? "-") titles=\(media.searchTitles.count)"
        qlog(.info, "query", "クエリ作成: \(summary)")
        return Built(options: options, summary: summary)
    }

    private static func hasValue(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        if v.isNull { return false }
        if let s = v.stringValue, s.isEmpty || s == "0" { return false }
        return true
    }

    /// ALToAniDB: AniDB の対応が無い SPECIAL/OVA/ONA は親作品の対応表を使う
    private static func aniToAniDB(_ media: AniMedia) async -> JSONValue? {
        let json = await AniZipClient.shared.mappings(anilistID: media.id, malID: media.idMal)
        if hasValue(json?["mappings"]?["anidb_id"]) { return json }
        guard let parent = media.parentForSpecialID else { return json }
        qlog(.debug, "query", "AniDB の対応が無いため親作品 \(parent) の対応表を使います")
        return await AniZipClient.shared.mappings(anilistID: parent, malID: nil) ?? json
    }

    /// ALtoAniDBEpisode の移植（ゼロ話の補正は省略）
    private static func aniToAniDBEpisode(media: AniMedia, episode: Int, meta: JSONValue) -> JSONValue? {
        guard let episodes = meta["episodes"]?.objectValue, !episodes.isEmpty else { return nil }
        let specialCount = meta["specialCount"]?.intValue ?? 0
        let episodeCount = meta["episodeCount"]?.intValue
        let direct = episodes[String(episode)]
        if specialCount == 0 || (media.episodes != nil && media.episodes == episodeCount && direct != nil) {
            return direct
        }
        qlog(.debug, "query", "AniList と AniDB で話数が食い違うため放送日で照合します（ep \(episode)）")

        var alDate: Date?
        let nodes = media.raw["airingSchedule"]?["nodes"]?.arrayValue ?? []
        if let at = nodes.first(where: { $0["episode"]?.intValue == episode })?["airingAt"]?.doubleValue {
            alDate = Date(timeIntervalSince1970: at)
        } else {
            let oneEpisode = media.episodes == 1 || (media.episodes == nil && ["MOVIE", "OVA", "SPECIAL"].contains(media.format ?? ""))
            if oneEpisode || episode <= 1 {
                if let d = date(media.raw["startDate"]) {
                    alDate = d
                } else if oneEpisode && episode <= 1, let d = date(media.raw["endDate"]) {
                    alDate = d
                } else {
                    return direct
                }
            } else {
                return direct
            }
        }
        guard let alDate else { return direct ?? episodes["1"] }
        return episodeByAirDate(alDate: alDate, episodes: Array(episodes.values), episode: episode) ?? direct
    }

    private static func date(_ v: JSONValue?) -> Date? {
        guard let y = v?["year"]?.intValue, let m = v?["month"]?.intValue, let d = v?["day"]?.intValue else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))
    }

    private static let airdateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func parseAirdate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = airdateFormatter.date(from: String(s.prefix(10))) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func episodeByAirDate(alDate: Date, episodes: [JSONValue], episode: Int) -> JSONValue? {
        var closest: [JSONValue] = []
        var best = Double.infinity
        for ep in episodes {
            guard let d = parseAirdate(ep["airdate"]?.stringValue) else { continue }
            let diff = abs(d.timeIntervalSince(alDate))
            if diff < best {
                best = diff
                closest = [ep]
            } else if diff == best {
                closest.append(ep)
            }
        }
        return closest.min { a, b in
            abs((a["episodeNumber"]?.doubleValue ?? 0) - Double(episode)) < abs((b["episodeNumber"]?.doubleValue ?? 0) - Double(episode))
        }
    }
}
