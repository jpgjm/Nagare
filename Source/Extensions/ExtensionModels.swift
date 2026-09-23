import Foundation

/// 拡張機能の設定項目（Shiru の SourceSetting）
struct ExtensionSettingDef: Identifiable, Hashable {
    enum Kind: String { case text, toggle, dropdown, multiselect }

    struct Option: Hashable {
        let label: String
        let value: String
    }

    let key: String
    let label: String
    let kind: Kind
    let description: String?
    let secret: Bool
    let required: Bool
    let placeholder: String?
    let options: [Option]
    let defaultValue: JSONValue

    var id: String { key }

    init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue,
              let label = json["label"]?.stringValue,
              let kind = json["type"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.key = key
        self.label = label
        self.kind = kind
        self.description = json["description"]?.stringValue
        self.secret = json["secret"]?.boolValue ?? false
        self.required = json["required"]?.boolValue ?? false
        self.placeholder = json["placeholder"]?.stringValue
        self.options = (json["options"]?.arrayValue ?? []).compactMap { o in
            guard let label = o["label"]?.stringValue, let value = o["value"]?.stringValue else { return nil }
            return Option(label: label, value: value)
        }
        self.defaultValue = json["default"] ?? .null
    }
}

/// インストール済みの拡張（マニフェスト 1 件分）
struct ExtensionSource: Identifiable, Hashable {
    /// Shiru の getKey: (locale || update[0]) + '/' + id
    let key: String
    let config: JSONValue

    var id: String { key }
    var extensionID: String { config["id"]?.stringValue ?? "?" }
    var name: String { config["name"]?.stringValue ?? extensionID }
    var version: String { config["version"]?.stringValue ?? "?" }
    var mains: [String] { config["main"]?.stringList ?? [] }
    var updates: [String] { config["update"]?.stringList ?? [] }
    var type: String { config["type"]?.stringValue ?? "torrent" }
    var nsfw: Bool { config["nsfw"]?.boolValue ?? false }
    var unregulated: Bool { config["unregulated"]?.boolValue ?? false }
    var deprecated: Bool { config["deprecated"]?.boolValue ?? false }
    var speed: String? { config["speed"]?.stringValue }
    var accuracy: String? { config["accuracy"]?.stringValue }
    var descriptionText: String? { config["description"]?.stringValue }
    var iconData: Data? {
        guard let icon = config["icon"]?.stringValue, !icon.hasPrefix("http") else { return nil }
        let base64 = icon.components(separatedBy: ",").last ?? icon
        return Data(base64Encoded: base64)
    }
    var iconURL: URL? {
        guard let icon = config["icon"]?.stringValue, icon.hasPrefix("http") else { return nil }
        return URL(string: icon)
    }
    var settingDefs: [ExtensionSettingDef] {
        (config["settings"]?.arrayValue ?? []).compactMap(ExtensionSettingDef.init(json:))
    }

    static func makeKey(_ config: JSONValue) -> String {
        let base = config["locale"]?.stringValue ?? config["update"]?.stringList.first ?? ""
        return base + "/" + (config["id"]?.stringValue ?? "")
    }
}

/// ユーザーごとの状態（有効/無効と設定値）
struct ExtensionState: Codable, Hashable {
    var enabled: Bool
    var settings: [String: JSONValue]
}

/// 実行時の状態
enum ExtensionRuntimeStatus: Equatable {
    case disabled
    case loading
    case active
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "無効"
        case .loading: return "読み込み中"
        case .active: return "有効"
        case .failed: return "エラー"
        }
    }
}

/// 検索結果（Shiru の TorrentResult）
struct TorrentResultItem: Identifiable, Hashable {
    let id: String
    let title: String
    let link: String
    let hash: String
    let seeders: Int
    let leechers: Int
    let downloads: Int
    let size: Int64
    let date: Date?
    let accuracy: String?
    let type: String?
    let searchType: String
    var extensionKeys: [String]
    var extensionNames: [String]

    init?(json: JSONValue, extensionKey: String, extensionName: String) {
        guard let link = json["link"]?.stringValue, !link.isEmpty else { return nil }
        let title = json["title"]?.stringValue ?? link
        var hash = (json["hash"]?.stringValue ?? "").lowercased()
        if hash.isEmpty, let parsed = TorrentResultItem.infoHash(fromMagnet: link) { hash = parsed }
        self.title = title
        self.link = link
        self.hash = hash
        // Shiru の dedupe と同じく 30000 以上は異常値として 0 扱い
        let seeders = json["seeders"]?.intValue ?? 0
        let leechers = json["leechers"]?.intValue ?? 0
        self.seeders = seeders < 30_000 ? seeders : 0
        self.leechers = leechers < 30_000 ? leechers : 0
        self.downloads = json["downloads"]?.intValue ?? 0
        self.size = Int64(json["size"]?.doubleValue ?? 0)
        self.date = json["date"]?.stringValue.flatMap { ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        self.accuracy = json["accuracy"]?.stringValue
        self.type = json["type"]?.stringValue
        self.searchType = json["searchType"]?.stringValue ?? "single"
        self.extensionKeys = [extensionKey]
        self.extensionNames = [extensionName]
        self.id = hash.isEmpty ? link : hash
    }

    /// 手動で作る（動作確認用のテスト再生など）
    init(manualTitle: String, link: String, hash: String, size: Int64 = 0) {
        self.id = hash.isEmpty ? link : hash
        self.title = manualTitle
        self.link = link
        self.hash = hash.lowercased()
        self.seeders = 0
        self.leechers = 0
        self.downloads = 0
        self.size = size
        self.date = nil
        self.accuracy = nil
        self.type = nil
        self.searchType = "single"
        self.extensionKeys = []
        self.extensionNames = []
    }

    var accuracyRank: Int {
        switch accuracy {
        case "high": return 2
        case "medium": return 1
        case "low": return 0
        default: return -1
        }
    }

    var isBatch: Bool { type == "batch" || searchType == "batch" }

    static func infoHash(fromMagnet link: String) -> String? {
        guard link.lowercased().hasPrefix("magnet:"),
              let items = URLComponents(string: link)?.queryItems else { return nil }
        for item in items where item.name.lowercased() == "xt" {
            if let value = item.value, value.lowercased().hasPrefix("urn:btih:") {
                return String(value.dropFirst("urn:btih:".count)).lowercased()
            }
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
