import Foundation

/// AniList の作品。拡張機能へは `raw`（AniList の応答そのまま）を `media` として渡す。
struct AniMedia: Identifiable, Hashable {
    let id: Int
    let raw: JSONValue

    init?(raw: JSONValue) {
        guard let id = raw["id"]?.intValue else { return nil }
        self.id = id
        self.raw = raw
    }

    var idMal: Int? { raw["idMal"]?.intValue }
    var format: String? { raw["format"]?.stringValue }
    var status: String? { raw["status"]?.stringValue }
    var episodes: Int? { raw["episodes"]?.intValue }
    var season: String? { raw["season"]?.stringValue }
    var seasonYear: Int? { raw["seasonYear"]?.intValue }
    var averageScore: Int? { raw["averageScore"]?.intValue }
    var isAdult: Bool { raw["isAdult"]?.boolValue ?? false }
    var nextAiringEpisode: Int? { raw["nextAiringEpisode"]?["episode"]?.intValue }
    var coverURL: URL? { raw["coverImage"]?["large"]?.stringValue.flatMap(URL.init(string:)) }
    var bannerURL: URL? { raw["bannerImage"]?.stringValue.flatMap(URL.init(string:)) }
    var descriptionText: String? { raw["description"]?.stringValue }
    var genres: [String] { raw["genres"]?.stringList ?? [] }
    var synonyms: [String] { raw["synonyms"]?.stringList ?? [] }

    var titleRomaji: String? { raw["title"]?["romaji"]?.stringValue }
    var titleEnglish: String? { raw["title"]?["english"]?.stringValue }
    var titleNative: String? { raw["title"]?["native"]?.stringValue }
    var titleUserPreferred: String? { raw["title"]?["userPreferred"]?.stringValue }

    var displayTitle: String {
        titleNative ?? titleUserPreferred ?? titleRomaji ?? titleEnglish ?? "#\(id)"
    }

    var subtitle: String {
        titleRomaji ?? titleEnglish ?? ""
    }

    var isMovie: Bool { format == "MOVIE" }

    /// Shiru の getMediaMaxEp（playable=false）に相当
    var maxEpisode: Int {
        let scheduleNodes = raw["airingSchedule"]?["nodes"]?.arrayValue ?? []
        let lastScheduled = scheduleNodes.last?["episode"]?.intValue ?? 0
        let value = max(lastScheduled, scheduleNodes.count, episodes ?? 0, nextAiringEpisode ?? 0)
        if value > 0 { return value }
        return status == "RELEASING" ? 1 : 0
    }

    /// 再生できる（放送済みの）最新話。Shiru の getMediaMaxEp（playable=true）に相当
    var playableEpisodes: Int {
        if let next = nextAiringEpisode, next - 1 > 0 { return next - 1 }
        if status == "NOT_YET_RELEASED" { return 0 }
        if let episodes, episodes > 0 { return episodes }
        return status == "RELEASING" ? 1 : max(maxEpisode, 1)
    }

    var formatLabel: String {
        switch format {
        case "TV": return "TV"
        case "TV_SHORT": return "TV（短編）"
        case "MOVIE": return "映画"
        case "SPECIAL": return "スペシャル"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "MUSIC": return "MV"
        default: return format ?? "?"
        }
    }

    var statusLabel: String {
        switch status {
        case "FINISHED": return "放送終了"
        case "RELEASING": return "放送中"
        case "NOT_YET_RELEASED": return "未放送"
        case "CANCELLED": return "中止"
        case "HIATUS": return "休止中"
        default: return status ?? "?"
        }
    }

    var seasonLabel: String? {
        guard let seasonYear else { return nil }
        let name: String
        switch season {
        case "WINTER": name = "冬"
        case "SPRING": name = "春"
        case "SUMMER": name = "夏"
        case "FALL": name = "秋"
        default: name = ""
        }
        return "\(seasonYear)年\(name)"
    }

    /// SPECIAL/OVA/ONA の親作品（ani.zip に AniDB の対応が無いときの代替）
    var parentForSpecialID: Int? {
        guard ["SPECIAL", "OVA", "ONA"].contains(format ?? "") else { return nil }
        let edges = raw["relations"]?["edges"]?.arrayValue ?? []
        let anime = edges.filter { $0["node"]?["type"]?.stringValue == "ANIME" }
        for type in ["PARENT", "PREQUEL", "SEQUEL"] {
            if let id = anime.first(where: { $0["relationType"]?.stringValue == type })?["node"]?["id"]?.intValue {
                return id
            }
        }
        return nil
    }

    /// Shiru の createTitles と同じ規則で検索用タイトルを作る
    var searchTitles: [String] {
        var grouped: [String] = []
        let candidates = [titleRomaji, titleEnglish, titleNative, titleUserPreferred].compactMap { $0 } + synonyms
        for name in candidates where name.count > 3 && !grouped.contains(name) {
            grouped.append(name)
        }
        var titles: [String] = []
        func append(_ title: String) {
            titles.append(title)
            if let m = title.range(of: #"Season (\d)"#, options: [.regularExpression, .caseInsensitive]) {
                let digit = title[m].filter(\.isNumber)
                titles.append(title.replacingCharacters(in: m, with: "S\(digit)"))
            } else if let m = title.range(of: #"(\d)(?:nd|rd|th) Season"#, options: [.regularExpression, .caseInsensitive]) {
                let digit = String(title[m].prefix(1))
                titles.append(title.replacingCharacters(in: m, with: "S\(digit)"))
            }
        }
        for title in grouped {
            var variants: [String] = []
            for v in [
                title,
                title.replacingOccurrences(of: "-", with: " "),
                title.replacingOccurrences(of: "'", with: ""),
                title.replacingOccurrences(of: "\"", with: ""),
                title.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: ""),
            ] where !variants.contains(v) {
                variants.append(v)
            }
            variants.forEach(append)
        }
        return titles
    }
}
