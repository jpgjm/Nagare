import Foundation
import SwiftUI

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let type: String
    let title: String?
    let lang: String?
    let codec: String?
    let selected: Bool
    let isDefault: Bool

    var label: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let lang, !lang.isEmpty { parts.append("[\(lang)]") }
        if let codec, !codec.isEmpty { parts.append(codec) }
        if parts.isEmpty { parts.append("トラック \(id)") }
        return parts.joined(separator: " ")
    }
}

/// プレイヤー画面の状態。mpv のプロパティ変化を受けて更新する。
@MainActor
final class PlayerModel: ObservableObject {
    @Published var timePos: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var bufferingForCache = false
    @Published var bufferingPercent: Int64 = 0
    @Published var cacheSeconds: Double = 0
    @Published var fileLoaded = false
    @Published var eof = false
    @Published var speed: Double = 1
    @Published var audioTracks: [MPVTrack] = []
    @Published var subtitleTracks: [MPVTrack] = []
    @Published var currentSid = "no"
    @Published var currentAid = "no"
    @Published var errorMessage: String?

    var core: MPVCore?
    private var lastLoggedCacheState: Bool?

    var isWaiting: Bool { !fileLoaded || bufferingForCache }

    func attach(_ core: MPVCore) {
        self.core = core
        // コールバックは MPVCore がメインスレッドで呼ぶ
        core.onProperty = { [weak self] name, value in
            MainActor.assumeIsolated { self?.handle(name, value) }
        }
        core.onEvent = { [weak self] name, detail in
            MainActor.assumeIsolated { self?.handleEvent(name, detail) }
        }
    }

    private func handle(_ name: String, _ value: MPVValue) {
        switch name {
        case "time-pos": timePos = value.double ?? timePos
        case "duration": duration = value.double ?? duration
        case "pause": paused = value.flag ?? paused
        case "paused-for-cache":
            let v = value.flag ?? false
            bufferingForCache = v
            if lastLoggedCacheState != v {
                lastLoggedCacheState = v
                qlog(v ? .info : .debug, "player", v ? "バッファ待ちで一時停止（\(Fmt.duration(timePos))）" : "バッファ待ち解除")
            }
        case "cache-buffering-state": bufferingPercent = value.int ?? 0
        case "demuxer-cache-duration": cacheSeconds = value.double ?? 0
        case "eof-reached": eof = value.flag ?? false
        case "speed": speed = value.double ?? 1
        case "sid": currentSid = value.string ?? "no"
        case "aid": currentAid = value.string ?? "no"
        case "track-list/count": refreshTracks()
        case "video-params/w":
            if let w = value.int, let h = core?.getString("video-params/h") {
                qlog(.info, "player", "映像: \(w)x\(h) \(core?.getString("video-codec") ?? "") / hwdec=\(core?.getString("hwdec-current") ?? "?")")
            }
        default: break
        }
    }

    private func handleEvent(_ name: String, _ detail: String?) {
        switch name {
        case "file-loaded":
            fileLoaded = true
            errorMessage = nil
            refreshTracks()
            qlog(.info, "player", "読み込み完了: 長さ \(Fmt.duration(core?.getDouble("duration") ?? 0)), コンテナ \(core?.getString("file-format") ?? "?")")
        case "end-file":
            if let detail {
                errorMessage = detail
            }
        default:
            break
        }
    }

    func refreshTracks() {
        guard let core, let count = core.getString("track-list/count").flatMap(Int.init) else { return }
        var audio: [MPVTrack] = []
        var subs: [MPVTrack] = []
        for i in 0..<count {
            let base = "track-list/\(i)"
            guard let type = core.getString("\(base)/type"),
                  let id = core.getString("\(base)/id").flatMap(Int.init) else { continue }
            let track = MPVTrack(
                id: id,
                type: type,
                title: core.getString("\(base)/title"),
                lang: core.getString("\(base)/lang"),
                codec: core.getString("\(base)/codec"),
                selected: core.getString("\(base)/selected") == "yes",
                isDefault: core.getString("\(base)/default") == "yes"
            )
            if type == "audio" { audio.append(track) }
            if type == "sub" { subs.append(track) }
        }
        audioTracks = audio
        subtitleTracks = subs
        qlog(.debug, "player", "トラック: 音声 \(audio.count) / 字幕 \(subs.count)")
    }

    // MARK: - 操作

    func togglePause() {
        core?.setFlag("pause", !paused)
    }

    func seek(by seconds: Double) {
        core?.command(["seek", String(seconds), "relative"])
    }

    func seek(to seconds: Double) {
        core?.command(["seek", String(max(0, seconds)), "absolute"])
    }

    func selectSubtitle(_ id: Int?) {
        core?.setString("sid", id.map(String.init) ?? "no")
        qlog(.info, "player", "字幕: \(id.map(String.init) ?? "オフ")")
    }

    func selectAudio(_ id: Int) {
        core?.setString("aid", String(id))
        qlog(.info, "player", "音声: \(id)")
    }

    func setSpeed(_ value: Double) {
        core?.setString("speed", String(value))
    }

    func shutdown() {
        guard core != nil else { return }
        core?.onProperty = nil
        core?.onEvent = nil
        core?.shutdown()
        core = nil
    }
}
