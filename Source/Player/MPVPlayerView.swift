import SwiftUI
import UIKit
import QuartzCore

/// MoltenVK が drawableSize を 1x1 に縮めてちらつく問題の回避（MPVKit のデモと同じ）
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

final class MPVPlayerViewController: UIViewController {
    let metalLayer = MPVMetalLayer()
    let url: URL
    let model: PlayerModel
    private var observers: [NSObjectProtocol] = []

    init(url: URL, model: PlayerModel) {
        self.url = url
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)

        guard let core = MPVCore(
            layer: metalLayer,
            verbose: AppSettings.mpvVerbose,
            audioLanguages: AppSettings.audioLanguages,
            subtitleLanguages: AppSettings.subtitleLanguages
        ) else {
            model.errorMessage = "プレイヤーを初期化できませんでした（ログを確認してください）"
            return
        }
        model.attach(core)
        core.loadFile(url)

        let center = NotificationCenter.default
        let model = self.model
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // 画面が無い間は映像出力を止める（復帰時の黒画面対策。音声は続く）
                model.core?.setString("vid", "no")
                qlog(.info, "player", "バックグラウンドへ: 映像出力を停止")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.core?.setString("vid", "auto")
                qlog(.info, "player", "フォアグラウンドへ: 映像出力を再開")
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    let model: PlayerModel

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        MPVPlayerViewController(url: url, model: model)
    }

    func updateUIViewController(_ uiViewController: MPVPlayerViewController, context: Context) {}

    /// SwiftUI がこのビューを本当に捨てるときだけ呼ばれる
    static func dismantleUIViewController(_ uiViewController: MPVPlayerViewController, coordinator: ()) {
        qlog(.debug, "player", "プレイヤービューを解体")
        uiViewController.model.shutdown()
        UIApplication.shared.isIdleTimerDisabled = false
        TorrentEngine.shared.isPlaying = false
    }
}
