import Foundation
import QuartzCore
import Libmpv

/// mpv から届いたプロパティ値
enum MPVValue: Equatable {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    var double: Double? { if case .double(let v) = self { return v }; return nil }
    var flag: Bool? { if case .flag(let v) = self { return v }; return nil }
    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
}

/// libmpv のハンドルとイベントループ。UI から独立させ、どのスレッドからでも呼べるようにする。
/// イベントは専用キューで読み、コールバックはメインスレッドで呼ぶ。
final class MPVCore: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "nagare.mpv.events", qos: .userInitiated)
    /// mpv が描画に使う。破棄が終わるまで保持する
    private let layer: CAMetalLayer

    /// (プロパティ名, 値) メインスレッドで呼ばれる
    var onProperty: ((String, MPVValue) -> Void)?
    /// ファイルの読み込み・終了などのイベント名。メインスレッドで呼ばれる
    var onEvent: ((String, String?) -> Void)?

    static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
        ("cache-buffering-state", MPV_FORMAT_INT64),
        ("track-list/count", MPV_FORMAT_INT64),
        ("sid", MPV_FORMAT_STRING),
        ("aid", MPV_FORMAT_STRING),
        ("speed", MPV_FORMAT_DOUBLE),
        ("video-params/w", MPV_FORMAT_INT64),
    ]

    init?(layer: CAMetalLayer, verbose: Bool, audioLanguages: String, subtitleLanguages: String) {
        self.layer = layer
        guard let h = mpv_create() else {
            qlog(.error, "mpv", "mpv_create に失敗")
            return nil
        }
        handle = h

        checkError(mpv_request_log_messages(h, verbose ? "v" : "info"), "request_log_messages")

        var wid = layer
        checkError(mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid), "wid")
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("alang", audioLanguages),
            ("slang", subtitleLanguages),
            ("subs-fallback", "yes"),
            ("sub-auto", "no"),
            ("embeddedfonts", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "64MiB"),
            ("demuxer-readahead-secs", "60"),
            // トレントのピース待ちで長く止まることがあるので FFmpeg 既定（タイムアウトなし）にする
            ("network-timeout", "0"),
            ("cache-pause-initial", "no"),
        ]
        for (name, value) in options {
            checkError(mpv_set_option_string(h, name, value), "option \(name)=\(value)")
        }

        let status = mpv_initialize(h)
        guard status >= 0 else {
            qlog(.error, "mpv", "mpv_initialize に失敗: \(String(cString: mpv_error_string(status)))")
            mpv_terminate_destroy(h)
            handle = nil
            return nil
        }
        for (name, format) in Self.observed {
            mpv_observe_property(h, 0, name, format)
        }
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        let version = getString("mpv-version") ?? "?"
        qlog(.info, "mpv", "初期化完了: \(version)（ログ \(verbose ? "詳細" : "通常")）")
    }

    deinit {
        if handle != nil {
            qlog(.warn, "mpv", "破棄前に shutdown されていません")
        }
    }

    // MARK: - 操作

    func loadFile(_ url: URL) {
        qlog(.info, "mpv", "loadfile: \(url.absoluteString)")
        command(["loadfile", url.absoluteString, "replace"])
    }

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let h = handle else { return -1 }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let status = mpv_command(h, &cargs)
        if status < 0 {
            qlog(.warn, "mpv", "コマンド失敗 \(args.joined(separator: " ")): \(String(cString: mpv_error_string(status)))")
        }
        return status
    }

    func setString(_ name: String, _ value: String) {
        guard let h = handle else { return }
        checkError(mpv_set_property_string(h, name, value), "set \(name)=\(value)")
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let h = handle else { return }
        var data: Int32 = value ? 1 : 0
        checkError(mpv_set_property(h, name, MPV_FORMAT_FLAG, &data), "set \(name)")
    }

    func getString(_ name: String) -> String? {
        guard let h = handle, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func getFlag(_ name: String) -> Bool {
        guard let h = handle else { return false }
        var data: Int32 = 0
        mpv_get_property(h, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }

    func getDouble(_ name: String) -> Double? {
        guard let h = handle else { return nil }
        var data = Double()
        let status = mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &data)
        return status >= 0 ? data : nil
    }

    /// 非同期に破棄する（mpv の後片付けがメインスレッドを待つことがあるため、メインで待たない）
    func shutdown(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard let h = handle else {
                DispatchQueue.main.async { completion?() }
                return
            }
            mpv_set_wakeup_callback(h, nil, nil)
            handle = nil
            mpv_terminate_destroy(h)
            _ = layer // 破棄が終わるまで保持
            qlog(.info, "mpv", "破棄しました")
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - イベント

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let h = self.handle {
                guard let eventPtr = mpv_wait_event(h, 0) else { break }
                let event = eventPtr.pointee
                if event.event_id == MPV_EVENT_NONE { break }
                self.process(event)
            }
        }
    }

    private func process(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let cName = prop.name else { return }
            let name = String(cString: cName)
            let value: MPVValue
            switch prop.format {
            case MPV_FORMAT_DOUBLE:
                value = prop.data.map { .double($0.load(as: Double.self)) } ?? .none
            case MPV_FORMAT_FLAG:
                value = prop.data.map { .flag($0.load(as: Int32.self) != 0) } ?? .none
            case MPV_FORMAT_INT64:
                value = prop.data.map { .int($0.load(as: Int64.self)) } ?? .none
            case MPV_FORMAT_STRING:
                if let p = prop.data?.load(as: UnsafePointer<CChar>?.self) {
                    value = .string(String(cString: p))
                } else {
                    value = .none
                }
            default:
                value = .none
            }
            DispatchQueue.main.async { [weak self] in self?.onProperty?(name, value) }

        case MPV_EVENT_LOG_MESSAGE:
            guard let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { return }
            let prefix = msg.prefix.map { String(cString: $0) } ?? "?"
            let levelName = msg.level.map { String(cString: $0) } ?? "info"
            var text = msg.text.map { String(cString: $0) } ?? ""
            while text.hasSuffix("\n") { text.removeLast() }
            guard !text.isEmpty else { return }
            let level: LogLevel
            switch levelName {
            case "fatal", "error": level = .error
            case "warn": level = .warn
            case "info": level = .info
            default: level = .debug
            }
            qlog(level, "mpv/\(prefix)", text)

        case MPV_EVENT_START_FILE:
            emit("start-file", nil)
        case MPV_EVENT_FILE_LOADED:
            emit("file-loaded", nil)
        case MPV_EVENT_PLAYBACK_RESTART:
            emit("playback-restart", nil)
        case MPV_EVENT_END_FILE:
            if let info = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                var detail = "reason=\(info.reason.rawValue)"
                if info.reason == MPV_END_FILE_REASON_ERROR {
                    detail = String(cString: mpv_error_string(info.error))
                    qlog(.error, "mpv", "再生エラーで終了: \(detail)")
                } else {
                    qlog(.info, "mpv", "ファイル終了（\(detail)）")
                }
                emit("end-file", info.reason == MPV_END_FILE_REASON_ERROR ? detail : nil)
            }
        case MPV_EVENT_SHUTDOWN:
            qlog(.info, "mpv", "shutdown イベント")
        default:
            break
        }
    }

    private func emit(_ name: String, _ detail: String?) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(name, detail) }
    }

    private func checkError(_ status: Int32, _ context: String) {
        if status < 0 {
            qlog(.warn, "mpv", "\(context): \(String(cString: mpv_error_string(status)))")
        }
    }
}
