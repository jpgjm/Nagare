import Foundation
import Network

/// mpv へトレントのファイルを渡すためのローカル HTTP サーバ（127.0.0.1 のみ）。
/// Range 要求に対応し、要求範囲のピースが揃うまで待ってから返す。
/// URL: http://127.0.0.1:<port>/stream/<ジョブ UUID>/<ファイル名>
final class StreamServer: @unchecked Sendable {
    static let shared = StreamServer()

    private let queue = DispatchQueue(label: "nagare.stream.server", qos: .userInitiated)
    private var listener: NWListener?
    private let lock = NSLock()
    private var sources: [UUID: StreamSource] = [:]
    private var _port: UInt16 = 0
    private var readyWaiters: [CheckedContinuation<UInt16?, Never>] = []
    private var connectionCounter = 0

    var port: UInt16 { lock.withLock { _port } }

    private init() {}

    /// 起動して待ち受けポートを返す（起動済みならそのまま）
    func start() async -> UInt16? {
        if let p = lock.withLock({ _port == 0 ? nil : _port }) { return p }
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            let shouldStart: Bool = lock.withLock {
                readyWaiters.append(cont)
                return listener == nil
            }
            if shouldStart { startListener() }
        }
    }

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            lock.withLock { self.listener = listener }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            qlog(.error, "server", "待ち受けを開始できません: \(error.localizedDescription)")
            finishWaiters(nil)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let p = listener?.port?.rawValue ?? 0
            lock.withLock { _port = p }
            qlog(.info, "server", "ストリーミングサーバ待ち受け開始: 127.0.0.1:\(p)")
            finishWaiters(p)
        case .failed(let error):
            qlog(.error, "server", "待ち受け失敗: \(error.localizedDescription)。作り直します")
            listener?.cancel()
            lock.withLock {
                listener = nil
                _port = 0
            }
            finishWaiters(nil)
        case .cancelled:
            qlog(.info, "server", "待ち受け終了")
        default:
            break
        }
    }

    private func finishWaiters(_ port: UInt16?) {
        let waiters: [CheckedContinuation<UInt16?, Never>] = lock.withLock {
            let w = readyWaiters
            readyWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume(returning: port) }
    }

    func register(_ source: StreamSource, for id: UUID) -> URL? {
        let p = port
        guard p != 0 else { return nil }
        lock.withLock { sources[id] = source }
        let name = source.displayName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "file"
        return URL(string: "http://127.0.0.1:\(p)/stream/\(id.uuidString)/\(name)")
    }

    func unregister(_ id: UUID) {
        lock.withLock { _ = sources.removeValue(forKey: id) }
    }

    private func source(for id: UUID) -> StreamSource? {
        lock.withLock { sources[id] }
    }

    private func accept(_ connection: NWConnection) {
        let number: Int = lock.withLock {
            connectionCounter += 1
            return connectionCounter
        }
        let handler = StreamConnection(connection: connection, number: number, queue: queue) { [weak self] id in
            self?.source(for: id)
        }
        handler.start()
    }
}

/// 1 接続分の処理。リクエストを 1 つ受けて応答したら閉じる（Connection: close）。
private final class StreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let number: Int
    private let queue: DispatchQueue
    private let lookup: (UUID) -> StreamSource?
    private var buffer = Data()
    private var task: Task<Void, Never>?
    private let chunkSize = 256 * 1024

    init(connection: NWConnection, number: Int, queue: DispatchQueue, lookup: @escaping (UUID) -> StreamSource?) {
        self.connection = connection
        self.number = number
        self.queue = queue
        self.lookup = lookup
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed(let error):
                qlog(.debug, "server", "#\(number) 接続失敗: \(error.localizedDescription)")
                task?.cancel()
                connection.cancel()
            case .cancelled:
                task?.cancel()
                // 接続とハンドラの循環参照を切る
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let header = String(decoding: headerData, as: UTF8.self)
                task = Task { await self.handle(header: header) }
                return
            }
            if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            receiveHeader()
        }
    }

    private func handle(header: String) async {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else {
            await respondError(400, "Bad Request")
            return
        }
        let method = requestLine[0]
        let path = requestLine[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "stream", let id = UUID(uuidString: parts[1]), let source = lookup(id) else {
            qlog(.warn, "server", "#\(number) 不明なパス: \(path)")
            await respondError(404, "Not Found")
            return
        }
        guard method == "GET" || method == "HEAD" else {
            await respondError(405, "Method Not Allowed")
            return
        }

        let size = source.fileSize
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
                    start = max(0, size - suffix)
                } else {
                    start = Int64(bounds[0]) ?? 0
                    if let e = Int64(bounds[1]) { end = min(e, size - 1) }
                }
                partial = true
            }
        }
        guard start < size, start <= end else {
            let head = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = try? await send(Data(head.utf8))
            finish()
            return
        }

        let length = end - start + 1
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(source.contentType)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n\r\n"

        qlog(.debug, "server", "#\(number) \(method) \(source.displayName) bytes=\(start)-\(end)（\(Fmt.bytes(length))）")
        do {
            try await send(Data(head.utf8))
            if method == "HEAD" {
                finish()
                return
            }
            var offset = start
            var sent: Int64 = 0
            while offset <= end {
                try Task.checkCancellation()
                let want = Int(min(Int64(chunkSize), end - offset + 1))
                let data = try await source.read(offset: offset, length: want)
                if data.isEmpty { break }
                try await send(data)
                offset += Int64(data.count)
                sent += Int64(data.count)
            }
            qlog(.debug, "server", "#\(number) 送信完了 \(Fmt.bytes(sent))")
        } catch {
            // シーク時は mpv が接続を切るので、ここに来るのは普通のこと
            qlog(.debug, "server", "#\(number) 送信中断: \(error.localizedDescription)")
        }
        finish()
    }

    private func respondError(_ code: Int, _ text: String) async {
        let head = "HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = try? await send(Data(head.utf8))
        finish()
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
