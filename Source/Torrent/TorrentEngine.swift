import Foundation
import LibtorrentKit
import Combine

/// 1 つのトレント（検索結果から開いたもの）
@MainActor
final class TorrentJob: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case adding
        case fetchingMetadata
        case choosingFile
        case preparing
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .adding: return "追加中"
            case .fetchingMetadata: return "メタデータ取得中"
            case .choosingFile: return "ファイル選択待ち"
            case .preparing: return "再生準備中"
            case .ready: return "再生可能"
            case .failed: return "失敗"
            }
        }
    }

    let id: UUID
    let title: String
    let link: String
    let hash: String
    let directory: URL
    let episodeHint: Int?
    /// 通し番号（2期のバッチで 13〜24 話と振られている場合など）
    let absoluteEpisodeHint: Int?
    let mediaTitle: String?
    let createdAt = Date()
    let flags = JobFlags()

    @Published var phase: Phase = .adding
    @Published var status: TorrentStatus?
    @Published var metadata: TorrentMetadata?
    @Published var selectedFile: TorrentFileInfo?
    @Published var streamURL: URL?
    @Published var lastError: String?
    @Published var completed = false

    var metadataTask: Task<Void, Never>?

    init(id: UUID, title: String, link: String, hash: String, directory: URL, episodeHint: Int?, absoluteEpisodeHint: Int?, mediaTitle: String?) {
        self.id = id
        self.title = title
        self.link = link
        self.hash = hash
        self.directory = directory
        self.episodeHint = episodeHint
        self.absoluteEpisodeHint = absoluteEpisodeHint
        self.mediaTitle = mediaTitle
    }

    /// ファイル名から話を探すときの候補（話数 → 通し番号の順）
    var episodeHints: [Int] {
        var hints: [Int] = []
        for h in [episodeHint, absoluteEpisodeHint].compactMap({ $0 }) where h > 0 && !hints.contains(h) {
            hints.append(h)
        }
        return hints
    }

    var videoFiles: [TorrentFileInfo] {
        (metadata?.files ?? []).filter { $0.size > 0 && TorrentEngine.videoExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var isActiveDownload: Bool {
        guard !completed, !flags.removed else { return false }
        if case .failed = phase { return false }
        guard let status else { return true }
        return !status.isPaused && status.state != .finished && status.state != .seeding && status.state != .stopped
    }
}

/// libtorrent セッションとジョブの管理
@MainActor
final class TorrentEngine: ObservableObject {
    static let shared = TorrentEngine()

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "webm", "mov", "ts", "m2ts", "wmv", "flv", "ogm"]

    /// Shiru の既定トラッカー（common/modules/util.js の trackers）から、libtorrent が使えるもの
    /// （udp / http / https）を、生きている可能性が高い順に並べたもの。wss:// は WebTorrent 専用なので除く。
    /// Shiru はすべてのトレントにこれを付けて追加するため、トラッカーの無い magnet（TsukiHime）や
    /// infohash だけのリンク（SeaDex）でもピアが見つかる。Nagare も magnet に同じものを付ける。
    static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "http://nyaa.tracker.wf:7777/announce",
        "https://tracker.nekobt.to/api/tracker/public/announce",
        "http://anidex.moe:6969/announce",
        "http://open.acgnxtracker.com:80/announce",
        "http://tracker.anirena.com:80/announce",
    ]

    /// magnet にまだ含まれていない既定トラッカーを &tr= で足す（既存のトラッカーが先に来る）
    static func addingDefaultTrackers(to magnet: String) -> String {
        let lower = magnet.lowercased().removingPercentEncoding ?? magnet.lowercased()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var result = magnet
        var added = 0
        for tracker in defaultTrackers where !lower.contains(tracker.lowercased()) {
            result += "&tr=" + (tracker.addingPercentEncoding(withAllowedCharacters: allowed) ?? tracker)
            added += 1
        }
        if added > 0 { qlog(.debug, "torrent", "既定のトラッカーを \(added) 件付加") }
        return result
    }

    /// 40 桁の 16 進数、または 32 桁の base32 の infohash か
    static func isBareInfoHash(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
            || s.range(of: "^[A-Za-z2-7]{32}$", options: .regularExpression) != nil
    }

    /// ログ用: トラッカーの passkey などを出さないよう、magnet は xt と dn だけにする
    static func redactedLink(_ link: String) -> String {
        if link.lowercased().hasPrefix("magnet:"), let items = URLComponents(string: link)?.queryItems {
            let kept = items.filter { $0.name == "xt" || $0.name == "dn" }.map { "\($0.name)=\($0.value ?? "")" }
            let trackers = items.filter { $0.name == "tr" }.count
            return "magnet:?" + kept.joined(separator: "&") + "（トラッカー \(trackers) 件）"
        }
        if let url = URL(string: link), let host = url.host {
            return "\(url.scheme ?? "?")://\(host)\(url.path)"
        }
        return link
    }

    @Published private(set) var jobs: [TorrentJob] = []
    @Published private(set) var sessionError: String?
    @Published var isPlaying = false {
        didSet { refreshKeepAlive() }
    }

    private var session: TorrentSession?
    private var eventTask: Task<Void, Never>?

    private init() {}

    // MARK: - セッション

    func ensureSession() async throws -> TorrentSession {
        if let session { return session }
        guard let ca = Bundle.main.url(forResource: "cacert-2026-08-13", withExtension: "pem") else {
            sessionError = "CA バンドルがアプリに含まれていません"
            qlog(.error, "torrent", "CA バンドル（cacert-2026-08-13.pem）がバンドルにありません")
            throw TorrentEngineError.missingCABundle
        }
        let version = RuntimeInfo.version
        let config = TorrentSessionConfiguration(
            userAgent: "Nagare/\(version)",
            listenPortRange: 6881...6891,
            enableDHT: AppSettings.torrentDHT,
            // LSD と UPnP はマルチキャストを使う（無料アカウントでは multicast entitlement が無い）ので切る
            enableLocalServiceDiscovery: false,
            enableUPnP: false,
            enableNATPMP: AppSettings.torrentNATPMP,
            caBundleURL: ca
        )
        do {
            let s = try TorrentSession(configuration: config)
            session = s
            sessionError = nil
            qlog(.info, "torrent", "セッション開始: DHT=\(config.enableDHT) NAT-PMP=\(config.enableNATPMP) ポート \(config.listenPortRange.lowerBound)-\(config.listenPortRange.upperBound)")
            startEventLoop(s)
            _ = await StreamServer.shared.start()
            return s
        } catch {
            sessionError = describeError(error)
            qlog(.error, "torrent", "セッションを作れません: \(describeError(error))")
            throw error
        }
    }

    private func startEventLoop(_ session: TorrentSession) {
        eventTask?.cancel()
        let stream = session.events
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
            qlog(.info, "torrent", "イベントストリーム終了")
        }
    }

    private func job(_ id: UUID?) -> TorrentJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    private func handle(_ event: TorrentEvent) {
        switch event {
        case .metadataReady(let id):
            qlog(.info, "torrent", "メタデータ到着: \(job(id)?.title ?? id.uuidString)")
        case .statusChanged(let id, let status):
            guard let job = job(id) else { return }
            let previous = job.status?.state
            job.status = status
            if previous != status.state {
                qlog(.debug, "torrent", "状態: \(job.title) → \(status.state.rawValue)（\(Fmt.percent(status.progress)), peers \(status.connectedPeers)）")
            }
            refreshKeepAlive()
        case .pieceCompleted:
            break
        case .completed(let id, let finalStatus):
            guard let job = job(id) else { return }
            job.flags.completed = true
            job.completed = true
            job.status = finalStatus
            qlog(.info, "torrent", "ダウンロード完了: \(job.title)（\(Fmt.bytes(finalStatus.completedBytes))）")
            refreshKeepAlive()
        case .stoppedAfterCompletion(let id):
            qlog(.debug, "torrent", "完了後に停止: \(job(id)?.title ?? id.uuidString)")
        case .error(let id, let error):
            let name = job(id)?.title ?? "(セッション)"
            qlog(.error, "torrent", "\(name): [\(error.operation.rawValue)/\(error.code)] \(error.description)")
            job(id)?.lastError = error.description
        }
    }

    // MARK: - 追加

    /// 検索結果を開く。同じハッシュのジョブがあればそれを返す
    func open(result: TorrentResultItem, episode: Int?, absoluteEpisode: Int? = nil, mediaTitle: String?) -> TorrentJob {
        if !result.hash.isEmpty, let existing = jobs.first(where: { $0.hash == result.hash && !$0.flags.removed }) {
            qlog(.info, "torrent", "既存のジョブを再利用: \(existing.title)")
            if case .failed = existing.phase { restart(existing) }
            return existing
        }
        let id = UUID()
        let folder = result.hash.isEmpty ? id.uuidString : result.hash
        let directory = AppSettings.torrentsDirectory.appendingPathComponent(folder, isDirectory: true)
        let job = TorrentJob(id: id, title: result.title, link: result.link, hash: result.hash, directory: directory, episodeHint: episode, absoluteEpisodeHint: absoluteEpisode, mediaTitle: mediaTitle)
        jobs.insert(job, at: 0)
        qlog(.info, "torrent", "ジョブ作成: \(result.title)（hash=\(result.hash.isEmpty ? "-" : result.hash), ep=\(episode.map(String.init) ?? "-"), 通し=\(absoluteEpisode.map(String.init) ?? "-"), 拡張=\(result.extensionNames.joined(separator: ","))）")
        qlog(.debug, "torrent", "リンク: \(Self.redactedLink(result.link))")
        start(job)
        return job
    }

    private func restart(_ job: TorrentJob) {
        job.phase = .adding
        job.lastError = nil
        start(job, isRestart: true)
    }

    private func start(_ job: TorrentJob, isRestart: Bool = false) {
        job.metadataTask?.cancel()
        job.metadataTask = Task { [weak self] in
            await self?.addAndFetchMetadata(job, isRestart: isRestart)
        }
    }

    private func addAndFetchMetadata(_ job: TorrentJob, isRestart: Bool) async {
        do {
            let session = try await ensureSession()
            if isRestart {
                // 前回の追加が残っていると同じ ID で追加できないので外しておく
                try? await session.remove(job.id, deleteFiles: false)
            }
            try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
            let source = try await makeSource(for: job)
            let limits = TorrentRateLimits(downloadBytesPerSecond: 0, uploadBytesPerSecond: AppSettings.uploadLimitKB * 1024)
            try await session.add(TorrentAddRequest(
                id: job.id,
                source: source,
                downloadDirectory: job.directory,
                beginsPaused: false,
                rateLimits: limits,
                // 完了後もハンドルを残す（同じバッチの別の話を選び直せるように）。Shiru と同じくシードを続ける
                completionPolicy: .seed
            ))
            qlog(.info, "torrent", "追加しました: \(job.title) → \(job.directory.lastPathComponent)")
            job.phase = .fetchingMetadata

            var metadata: TorrentMetadata?
            var attempt = 0
            while metadata == nil {
                attempt += 1
                if Task.isCancelled || job.flags.removed { return }
                do {
                    metadata = try await session.metadata(for: job.id)
                } catch let error as TorrentError where error.code == .timedOut || error.code == .metadataUnavailable {
                    qlog(.info, "torrent", "メタデータ待ち（\(attempt) 回目, peers \(job.status?.connectedPeers ?? 0)）")
                    if attempt >= 20 { throw error }
                }
            }
            guard let metadata else { return }
            job.metadata = metadata
            qlog(.info, "torrent", "メタデータ: \(metadata.name)（\(metadata.files.count) ファイル, \(Fmt.bytes(metadata.totalBytes)), ピース \(Fmt.bytes(Int64(metadata.pieceLength))) × \(metadata.pieceCount)）")

            let videos = job.videoFiles
            if videos.isEmpty {
                throw TorrentEngineError.noVideo
            }
            if videos.count == 1 {
                await select(videos[0], in: job)
                return
            }
            let hints = job.episodeHints
            if !hints.isEmpty, let picked = EpisodeMatcher.pick(from: videos, hints: hints) {
                qlog(.info, "torrent", "動画 \(videos.count) 件から自動選択（候補 \(hints)）: \(picked.path)")
                await select(picked, in: job)
                return
            }
            qlog(.info, "torrent", "動画 \(videos.count) 件から話を特定できませんでした（候補 \(hints)）。選択待ち")
            job.phase = .choosingFile
        } catch is CancellationError {
            qlog(.debug, "torrent", "中断: \(job.title)")
        } catch {
            job.phase = .failed(describeError(error))
            job.lastError = describeError(error)
            qlog(.error, "torrent", "\(job.title): \(describeError(error))")
        }
    }

    private func makeSource(for job: TorrentJob) async throws -> TorrentSource {
        let link = job.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.lowercased().hasPrefix("magnet:") {
            let magnet = Self.addingDefaultTrackers(to: link)
            guard let url = URL(string: magnet) ?? URL(string: link) else { throw TorrentEngineError.unsupportedLink }
            return .magnet(url)
        }
        // SeaDex などは infohash だけをリンクとして返す
        if Self.isBareInfoHash(link), let url = URL(string: Self.addingDefaultTrackers(to: "magnet:?xt=urn:btih:\(link)")) {
            qlog(.info, "torrent", "リンクが infohash のみのため magnet を作ります（既定のトラッカーを付加）")
            return .magnet(url)
        }
        if link.hasPrefix("http://") || link.hasPrefix("https://"), let url = URL(string: link) {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status), data.first == UInt8(ascii: "d") else {
                    throw TorrentEngineError.badTorrentFile(status)
                }
                qlog(.info, "torrent", ".torrent を取得（\(data.count) bytes）: \(url.host ?? "")")
                return .torrentData(data)
            } catch {
                qlog(.warn, "torrent", ".torrent の取得に失敗: \(error.localizedDescription)")
                if !job.hash.isEmpty, let magnet = URL(string: Self.addingDefaultTrackers(to: "magnet:?xt=urn:btih:\(job.hash)")) {
                    qlog(.info, "torrent", "ハッシュから magnet を作ります（既定のトラッカー + DHT）")
                    return .magnet(magnet)
                }
                throw error
            }
        }
        if !job.hash.isEmpty, let magnet = URL(string: Self.addingDefaultTrackers(to: "magnet:?xt=urn:btih:\(job.hash)")) {
            qlog(.info, "torrent", "リンク形式が不明なため、ハッシュから magnet を作ります")
            return .magnet(magnet)
        }
        throw TorrentEngineError.unsupportedLink
    }

    /// 再生するファイルを決め、ストリーミング URL を用意する
    func select(_ file: TorrentFileInfo, in job: TorrentJob) async {
        guard let session, let metadata = job.metadata else { return }
        job.phase = .preparing
        // 選び直した場合は新しいファイルがまだ揃っていないので完了扱いを解除する
        job.flags.completed = false
        job.completed = false
        do {
            try await session.selectFiles(for: job.id, selectedFileIndexes: [file.index], primaryFileIndex: file.index)
            job.selectedFile = file
            let source = StreamSource(session: session, torrentID: job.id, file: file, pieceLength: metadata.pieceLength, directory: job.directory, flags: job.flags)
            await source.primeWindow()
            guard await StreamServer.shared.start() != nil, let url = StreamServer.shared.register(source, for: job.id) else {
                throw TorrentEngineError.serverUnavailable
            }
            job.streamURL = url
            job.phase = .ready
            qlog(.info, "torrent", "再生ファイル: \(file.path)（\(Fmt.bytes(file.size))）→ \(url.absoluteString)")
        } catch {
            job.phase = .failed(describeError(error))
            qlog(.error, "torrent", "ファイル選択に失敗: \(describeError(error))")
        }
    }

    // MARK: - 操作

    func pause(_ job: TorrentJob) async {
        guard let session else { return }
        do {
            try await session.pause(job.id)
            qlog(.info, "torrent", "一時停止: \(job.title)")
        } catch {
            qlog(.warn, "torrent", "一時停止できません: \(describeError(error))")
        }
    }

    func resume(_ job: TorrentJob) async {
        guard let session else { return }
        do {
            try await session.start(job.id)
            qlog(.info, "torrent", "再開: \(job.title)")
        } catch {
            qlog(.warn, "torrent", "再開できません: \(describeError(error))")
        }
    }

    func remove(_ job: TorrentJob, deleteFiles: Bool) async {
        job.flags.removed = true
        job.metadataTask?.cancel()
        StreamServer.shared.unregister(job.id)
        if let session {
            do {
                try await session.remove(job.id, deleteFiles: deleteFiles)
            } catch {
                qlog(.debug, "torrent", "remove: \(describeError(error))")
            }
        }
        if deleteFiles {
            try? FileManager.default.removeItem(at: job.directory)
        }
        jobs.removeAll { $0.id == job.id }
        qlog(.info, "torrent", "削除: \(job.title)（ファイル\(deleteFiles ? "も削除" : "は残す")）")
        refreshKeepAlive()
    }

    /// ダウンロード済みファイルの合計サイズ
    func storageUsage() -> Int64 {
        let root = AppSettings.torrentsDirectory
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// 進行中のジョブが無いときだけ、ダウンロード済みファイルをすべて消す
    func deleteAllDownloads() -> Bool {
        guard jobs.isEmpty else { return false }
        try? FileManager.default.removeItem(at: AppSettings.torrentsDirectory)
        qlog(.info, "torrent", "ダウンロード済みファイルをすべて削除しました")
        return true
    }

    // MARK: - バックグラウンド

    func refreshKeepAlive() {
        let downloading = jobs.contains { $0.isActiveDownload }
        BackgroundKeepAlive.shared.update(shouldRun: AppSettings.keepAlive && (downloading || isPlaying),
                                          reason: isPlaying ? "再生中" : (downloading ? "ダウンロード中" : "なし"))
    }
}

enum TorrentEngineError: LocalizedError {
    case missingCABundle
    case noVideo
    case badTorrentFile(Int)
    case unsupportedLink
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCABundle: return "CA バンドルがありません"
        case .noVideo: return "このトレントには動画ファイルがありません"
        case .badTorrentFile(let code): return ".torrent を取得できません（HTTP \(code) または形式不正）"
        case .unsupportedLink: return "対応していないリンク形式です"
        case .serverUnavailable: return "ストリーミングサーバを起動できません"
        }
    }
}

/// ファイル名から話数を当てる（バッチの中から目的の話を選ぶ）。
/// 強い一致（S01E05, E05, " - 05", [05], 第5話）を先に試し、1 件に絞れなければ弱い一致（単独の数字）を試す。
/// ノンクレ OP/ED・特典・PV などは候補から外す。
enum EpisodeMatcher {
    private static func strongPatterns(_ e: Int) -> [String] {
        [
            #"(?i)\bS\d{1,2}\s?E0*\#(e)(?:v\d)?\b"#,
            #"(?i)(?:^|[\s_\[\(.-])E[Pp]?\.?\s?0*\#(e)(?:v\d)?(?![\dA-Za-z])"#,
            #"\s-\s0*\#(e)(?:v\d)?(?:\s|\.|\[|\(|$)"#,
            #"\[0*\#(e)(?:v\d)?\]"#,
            #"第0*\#(e)[話集]"#,
            #"(?i)episode\s?0*\#(e)(?![\d])"#,
        ]
    }

    private static func weakPattern(_ e: Int) -> String {
        #"(?<![\dA-Za-z.])0*\#(e)(?:v\d)?(?![\dA-Za-z])"#
    }

    private static let extraPattern = #"(?i)(\bNC(OP|ED)\d*\b|creditless|\b(OP|ED)\s?\d{0,2}\b|\bPV\s?\d*\b|\bCM\s?\d*\b|trailer|preview|menu|\bextras?\b|\bspecials?\b|\bbonus\b|映像特典|ノンクレジット)"#

    static func isExtra(_ path: String) -> Bool {
        path.range(of: extraPattern, options: .regularExpression) != nil
    }

    static func strongMatch(_ path: String, episode: Int) -> Bool {
        let name = (path as NSString).lastPathComponent
        return strongPatterns(episode).contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    static func weakMatch(_ path: String, episode: Int) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.range(of: weakPattern(episode), options: .regularExpression) != nil
    }

    static func matches(_ path: String, episode: Int) -> Bool {
        strongMatch(path, episode: episode) || weakMatch(path, episode: episode)
    }

    /// 1 件に絞れたときだけ返す
    static func pick(from files: [TorrentFileInfo], hints: [Int]) -> TorrentFileInfo? {
        let main = files.filter { !isExtra($0.path) }
        let pool = main.isEmpty ? files : main
        for hint in hints {
            let strong = pool.filter { strongMatch($0.path, episode: hint) }
            if strong.count == 1 { return strong[0] }
            if strong.count > 1 {
                qlog(.debug, "torrent", "第\(hint)話の強い一致が \(strong.count) 件: \(strong.map { ($0.path as NSString).lastPathComponent })")
            }
        }
        for hint in hints {
            let weak = pool.filter { weakMatch($0.path, episode: hint) }
            if weak.count == 1 { return weak[0] }
        }
        return nil
    }
}

/// エラーを人が読める文にする（TorrentError は localizedDescription が汎用文になるため）
func describeError(_ error: Error) -> String {
    if let e = error as? TorrentError {
        return "\(e.description)（\(e.operation.rawValue)/\(e.code)）"
    }
    return error.localizedDescription
}
