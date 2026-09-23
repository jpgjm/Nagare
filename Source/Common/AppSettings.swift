import Foundation

/// UserDefaults のキーと既定値。View では @AppStorage、それ以外は `AppSettings.xxx` で読む。
enum AppSettings {
    enum Key {
        static let resolution = "search.resolution"
        static let showAdult = "search.showAdult"
        static let keepAlive = "background.keepAlive"
        static let mpvVerbose = "player.mpvVerbose"
        static let audioLanguages = "player.alang"
        static let subtitleLanguages = "player.slang"
        static let seekShort = "player.seekShort"
        static let seekLong = "player.seekLong"
        static let torrentDHT = "torrent.dht"
        static let torrentNATPMP = "torrent.natpmp"
        static let uploadLimitKB = "torrent.uploadLimitKB"
    }

    enum Default {
        static let resolution = "1080"
        static let showAdult = false
        static let keepAlive = true
        static let mpvVerbose = false
        static let audioLanguages = "jpn,ja"
        static let subtitleLanguages = "jpn,ja,eng,en"
        static let seekShort = 10
        static let seekLong = 85
        static let torrentDHT = true
        static let torrentNATPMP = true
        static let uploadLimitKB = 0
    }

    private static var defaults: UserDefaults { .standard }

    static var resolution: String { defaults.string(forKey: Key.resolution) ?? Default.resolution }
    static var showAdult: Bool { defaults.object(forKey: Key.showAdult) as? Bool ?? Default.showAdult }
    static var keepAlive: Bool { defaults.object(forKey: Key.keepAlive) as? Bool ?? Default.keepAlive }
    static var mpvVerbose: Bool { defaults.object(forKey: Key.mpvVerbose) as? Bool ?? Default.mpvVerbose }
    static var audioLanguages: String { defaults.string(forKey: Key.audioLanguages) ?? Default.audioLanguages }
    static var subtitleLanguages: String { defaults.string(forKey: Key.subtitleLanguages) ?? Default.subtitleLanguages }
    static var seekShort: Int { defaults.object(forKey: Key.seekShort) as? Int ?? Default.seekShort }
    static var seekLong: Int { defaults.object(forKey: Key.seekLong) as? Int ?? Default.seekLong }
    static var torrentDHT: Bool { defaults.object(forKey: Key.torrentDHT) as? Bool ?? Default.torrentDHT }
    static var torrentNATPMP: Bool { defaults.object(forKey: Key.torrentNATPMP) as? Bool ?? Default.torrentNATPMP }
    static var uploadLimitKB: Int { defaults.object(forKey: Key.uploadLimitKB) as? Int ?? Default.uploadLimitKB }

    /// 保存場所
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var torrentsDirectory: URL { documents.appendingPathComponent("Torrents", isDirectory: true) }
    static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nagare", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var cachesDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nagare", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
