import Foundation
import Combine

/// ログの重要度。Mac が無く Xcode のコンソールを見られないため、
/// すべてのログはアプリ内（ログタブ）で閲覧・書き出しできるようにしている。
enum LogLevel: Int, Codable, CaseIterable, Comparable, Identifiable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    var japanese: String {
        switch self {
        case .debug: return "デバッグ"
        case .info: return "情報"
        case .warn: return "警告"
        case .error: return "エラー"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct LogEntry: Identifiable, Hashable {
    let id: Int
    let date: Date
    let level: LogLevel
    let category: String
    let message: String

    var line: String {
        "\(AppLog.timestampFormatter.string(from: date)) [\(level.label)] [\(category)] \(message)"
    }
}

/// どのスレッドからでも呼べるログ記録。
/// - メモリ上に直近 `maxEntries` 件を保持（ログタブ表示用）
/// - Documents/Logs/nagare-<日付>.log に追記（書き出し・「ファイル」アプリ用）
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    let maxEntries = 5_000

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var nextID = 0
    private let fileQueue = DispatchQueue(label: "nagare.log.file", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?

    /// UI 側（LogStore）へ通知する。メインスレッドで配信する。
    let updates = PassthroughSubject<Void, Never>()

    var logDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Logs", isDirectory: true)
    }

    private init() {}

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        let now = Date()
        lock.lock()
        let entry = LogEntry(id: nextID, date: now, level: level, category: category, message: message)
        nextID += 1
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        let line = entry.line + "\n"
        fileQueue.async { [weak self] in
            self?.appendToFile(line, date: now)
        }
        DispatchQueue.main.async { [weak self] in
            self?.updates.send()
        }
    }

    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clearMemory() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.updates.send() }
    }

    /// 書き出し用のファイルを作る。表示中（フィルタ後）のログをそのまま書く。
    func exportFile(entries: [LogEntry]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogExport", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("nagare-log-\(f.string(from: Date())).txt")
        var text = RuntimeInfo.summaryLines().joined(separator: "\n") + "\n\n"
        text += entries.map(\.line).joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Documents/Logs 以下のログファイル一覧（新しい順）
    func logFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func appendToFile(_ line: String, date: Date) {
        let name = "nagare-\(Self.fileDateFormatter.string(from: date)).log"
        let url = logDirectory.appendingPathComponent(name)
        if currentFileURL != url {
            try? fileHandle?.close()
            fileHandle = nil
            currentFileURL = url
            do {
                try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                fileHandle = try FileHandle(forWritingTo: url)
                try fileHandle?.seekToEnd()
            } catch {
                fileHandle = nil
            }
        }
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            currentFileURL = nil
        }
    }
}

/// ログ記録の入口。どのスレッドからでも呼べる。
func qlog(_ level: LogLevel, _ category: String, _ message: @autoclosure () -> String) {
    AppLog.shared.log(level, category, message())
}
