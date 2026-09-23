import Foundation
import AVFoundation

/// ダウンロード中・再生中にアプリがバックグラウンドで止まらないよう、無音を流し続ける。
/// UIBackgroundModes: audio を使う（entitlement 不要で無料 Personal Team でも使える）。
/// 再生中は mpv 自身が音を出すので実質不要だが、一時停止中にも止まらないよう併用する。
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {
        _ = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            MainActor.assumeIsolated {
                BackgroundKeepAlive.shared.handleInterruption(type)
            }
        }
    }

    func update(shouldRun: Bool, reason: String) {
        if shouldRun && !isRunning {
            start(reason: reason)
        } else if !shouldRun && isRunning {
            stop()
        }
    }

    private func start(reason: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            // 再生中はプレイヤーが .playback を設定済み。そのときは触らない
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: Self.silentWAV())
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            player?.play()
            isRunning = true
            qlog(.info, "keepalive", "バックグラウンド継続を開始（\(reason)）")
        } catch {
            qlog(.error, "keepalive", "バックグラウンド継続を開始できません: \(error.localizedDescription)")
        }
    }

    private func stop() {
        player?.stop()
        isRunning = false
        qlog(.info, "keepalive", "バックグラウンド継続を停止")
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isRunning else { return }
        switch type {
        case .began:
            qlog(.info, "keepalive", "オーディオ割り込み開始")
        case .ended:
            qlog(.info, "keepalive", "オーディオ割り込み終了。無音再生を再開")
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        default:
            break
        }
    }

    /// 1 秒の無音 WAV（16bit モノラル 8kHz）を実行時に作る
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate)
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func append<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); append(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
