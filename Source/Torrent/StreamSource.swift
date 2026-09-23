import Foundation
import LibtorrentKit

/// ジョブの状態のうち、ストリーミング側（任意のスレッド）から読むもの
final class JobFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _completed = false
    private var _removed = false

    var completed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _completed }
        set { lock.lock(); _completed = newValue; lock.unlock() }
    }

    var removed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _removed }
        set { lock.lock(); _removed = newValue; lock.unlock() }
    }
}

enum StreamError: LocalizedError {
    case removed
    case cancelled
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .removed: return "トレントが削除されました"
        case .cancelled: return "読み込みが中断されました"
        case .readFailed(let s): return "ファイルを読めません: \(s)"
        }
    }
}

/// トレント内の 1 ファイルを「必要な範囲のピースが揃うまで待ってから読む」バイト列として見せる。
/// StreamServer（HTTP）経由で mpv が読む。シークなどで読み位置が飛んだら
/// libtorrent の優先度（ストリーミング窓）を読み位置へ移す。
final class StreamSource: @unchecked Sendable {
    let session: TorrentSession
    let torrentID: UUID
    let fileIndex: Int
    let fileSize: Int64
    let fileTorrentOffset: Int64
    let pieceLength: Int
    let fileURL: URL
    let flags: JobFlags
    let displayName: String

    /// 先読みの設定
    let criticalBytes: Int64 = 24 * 1_048_576
    let warmBytes: Int64 = 128 * 1_048_576
    let consumptionBytesPerSecond: Int64 = 2 * 1_048_576
    /// 読み位置がこれ以上進んだら窓を前へ動かす
    let windowAdvanceBytes: Int64 = 16 * 1_048_576

    private let lock = NSLock()
    private var windowOffset: Int64 = -1
    private var handle: FileHandle?
    private var lastLoggedWaitPiece = -1

    init(session: TorrentSession, torrentID: UUID, file: TorrentFileInfo, pieceLength: Int, directory: URL, flags: JobFlags) {
        self.session = session
        self.torrentID = torrentID
        self.fileIndex = file.index
        self.fileSize = file.size
        self.fileTorrentOffset = file.torrentOffset
        self.pieceLength = pieceLength
        self.fileURL = directory.appendingPathComponent(file.path)
        self.flags = flags
        self.displayName = (file.path as NSString).lastPathComponent
    }

    deinit {
        try? handle?.close()
    }

    var contentType: String {
        switch fileURL.pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "ts", "m2ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

    /// offset から最大 length バイトを読む（必要なピースが揃うまで待つ）
    func read(offset: Int64, length: Int) async throws -> Data {
        let end = min(offset + Int64(length), fileSize)
        guard end > offset else { return Data() }
        if flags.removed { throw StreamError.removed }
        if !flags.completed {
            await moveWindowIfNeeded(offset)
            try await waitForPieces(from: offset, to: end)
        }
        return try readFile(offset: offset, count: Int(end - offset))
    }

    /// 再生開始前に先頭へ窓を置く
    func primeWindow() async {
        await moveWindowIfNeeded(0, force: true)
    }

    private func moveWindowIfNeeded(_ offset: Int64, force: Bool = false) async {
        let (current, needs): (Int64, Bool) = lock.withLock {
            let current = windowOffset
            let needs = force || current < 0 || offset < current || offset - current >= windowAdvanceBytes
            if needs { windowOffset = offset }
            return (current, needs)
        }
        guard needs, !flags.completed else { return }
        let isJump = current >= 0 && (offset < current || offset - current > warmBytes)
        do {
            let window = try await session.updateStreamingWindow(
                for: torrentID,
                fileIndex: fileIndex,
                byteOffset: offset,
                criticalBufferBytes: criticalBytes,
                warmBufferBytes: warmBytes,
                consumptionBytesPerSecond: consumptionBytesPerSecond,
                prioritizeFirstAndLastPieces: true
            )
            qlog(isJump ? .info : .debug, "stream", "\(isJump ? "シーク" : "先読み")窓: offset=\(Fmt.bytes(offset)) ピース \(window.playbackPieceIndex)（期限付き \(window.deadlinePieceIndexes.count) 個, 優先 \(window.prioritizedPieceIndexes.count) 個）")
        } catch {
            qlog(.warn, "stream", "ストリーミング窓の更新に失敗: \(describeError(error))")
        }
    }

    private func waitForPieces(from start: Int64, to end: Int64) async throws {
        let first = Int((fileTorrentOffset + start) / Int64(pieceLength))
        let last = Int((fileTorrentOffset + end - 1) / Int64(pieceLength))
        let began = Date()
        var warned = false
        var consecutiveErrors = 0
        while true {
            if flags.completed { return }
            if flags.removed { throw StreamError.removed }
            try Task.checkCancellation()
            do {
                let completion = try await session.pieceCompletion(for: torrentID)
                consecutiveErrors = 0
                if completion.areComplete(in: first...last) {
                    let waited = Date().timeIntervalSince(began)
                    if waited > 2 {
                        qlog(.info, "stream", String(format: "ピース %d〜%d が揃いました（%.1f 秒待ち）", first, last, waited))
                    }
                    return
                }
            } catch is CancellationError {
                throw StreamError.cancelled
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors == 1 || consecutiveErrors % 20 == 0 {
                    qlog(.warn, "stream", "ピース状態を取得できません（\(consecutiveErrors) 回目）: \(describeError(error))")
                }
            }
            if !warned, Date().timeIntervalSince(began) > 5 {
                warned = true
                let shouldLog: Bool = lock.withLock {
                    let changed = lastLoggedWaitPiece != first
                    lastLoggedWaitPiece = first
                    return changed
                }
                if shouldLog {
                    qlog(.info, "stream", "ピース \(first)〜\(last) を待っています（offset \(Fmt.bytes(start))）")
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func readFile(offset: Int64, count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        do {
            if handle == nil {
                handle = try FileHandle(forReadingFrom: fileURL)
            }
            try handle?.seek(toOffset: UInt64(offset))
            let data = try handle?.read(upToCount: count) ?? Data()
            if data.count < count {
                // ピースは揃っているのに短い → ファイルの伸長前。開き直して再試行
                try? handle?.close()
                handle = try FileHandle(forReadingFrom: fileURL)
                try handle?.seek(toOffset: UInt64(offset))
                let retry = try handle?.read(upToCount: count) ?? Data()
                if retry.count < count {
                    qlog(.warn, "stream", "読み取りが短い: 要求 \(count) / 取得 \(retry.count)（offset \(offset)）")
                }
                return retry
            }
            return data
        } catch {
            try? handle?.close()
            handle = nil
            throw StreamError.readFailed(error.localizedDescription)
        }
    }
}
