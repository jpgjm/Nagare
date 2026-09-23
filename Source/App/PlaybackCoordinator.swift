import SwiftUI

/// 「トレントを開く → 準備画面 → プレイヤー」の画面遷移をアプリの最上位でまとめて扱う
@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    struct PlayingItem: Identifiable {
        let job: TorrentJob
        let url: URL
        var id: UUID { job.id }
    }

    @Published var preparingJob: TorrentJob?
    @Published var playing: PlayingItem?
    /// 準備シートが閉じ終わったら表示するもの
    private var pendingPlay: PlayingItem?

    private init() {}

    func open(_ result: TorrentResultItem, episode: Int?, absoluteEpisode: Int? = nil, mediaTitle: String?) {
        let job = TorrentEngine.shared.open(result: result, episode: episode, absoluteEpisode: absoluteEpisode, mediaTitle: mediaTitle)
        showPreparation(job)
    }

    func showPreparation(_ job: TorrentJob) {
        pendingPlay = nil
        playing = nil
        preparingJob = job
    }

    func play(_ job: TorrentJob) {
        guard let url = job.streamURL else { return }
        // 準備画面の onAppear / onChange から同時に呼ばれても 1 回だけにする
        if playing?.id == job.id || pendingPlay?.id == job.id {
            qlog(.debug, "player", "重複した再生要求を無視")
            return
        }
        let item = PlayingItem(job: job, url: url)
        if preparingJob != nil {
            // シートの表示中に全画面を重ねると、表示が作り直されて mpv が消えることがある。
            // シートの onDismiss（sheetDidDismiss）まで待ってから出す
            pendingPlay = item
            preparingJob = nil
            qlog(.debug, "player", "準備画面を閉じてから再生します")
        } else {
            playing = item
        }
    }

    func sheetDidDismiss() {
        guard let item = pendingPlay else { return }
        pendingPlay = nil
        playing = item
    }

    func closePlayer() {
        pendingPlay = nil
        playing = nil
    }
}

/// トレントの追加からファイル選択・再生開始までの画面
struct PlaybackPrepView: View {
    @ObservedObject var job: TorrentJob
    @ObservedObject private var coordinator = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var autoPlayed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(job.title).font(.subheadline)
                    LabeledContent("状態", value: job.phase.label)
                    if let s = job.status {
                        LabeledContent("ピア", value: "\(s.connectedPeers)")
                        LabeledContent("速度", value: "↓\(Fmt.rate(s.downloadRate))  ↑\(Fmt.rate(s.uploadRate))")
                        if s.hasMetadata {
                            ProgressView(value: s.progress) {
                                Text("\(Fmt.bytes(s.completedBytes)) / \(Fmt.bytes(s.totalBytes))")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    if let m = job.metadata {
                        LabeledContent("サイズ", value: Fmt.bytes(m.totalBytes))
                        LabeledContent("ファイル数", value: "\(m.files.count)")
                    }
                }

                switch job.phase {
                case .adding, .fetchingMetadata, .preparing:
                    Section {
                        HStack {
                            ProgressView()
                            Text(job.phase == .fetchingMetadata ? "ピアを探してメタデータを取得しています…" : "準備しています…")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .choosingFile:
                    Section("再生するファイルを選んでください") {
                        ForEach(job.videoFiles) { file in
                            Button {
                                Task { await TorrentEngine.shared.select(file, in: job) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text((file.path as NSString).lastPathComponent)
                                        .foregroundStyle(job.episodeHints.contains { EpisodeMatcher.matches(file.path, episode: $0) } ? Color.accentColor : .primary)
                                    Text(Fmt.bytes(file.size)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .ready:
                    Section {
                        Button {
                            coordinator.play(job)
                        } label: {
                            Label("再生", systemImage: "play.fill")
                        }
                        if job.videoFiles.count > 1 {
                            Menu("別のファイルを選ぶ") {
                                ForEach(job.videoFiles) { file in
                                    Button((file.path as NSString).lastPathComponent) {
                                        Task { await TorrentEngine.shared.select(file, in: job) }
                                    }
                                }
                            }
                        }
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Text("詳しくはログタブを確認してください").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let e = job.lastError, job.phase != .failed(e) {
                    Section("直近のエラー") {
                        Text(e).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("再生の準備")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onChange(of: job.phase) { _, phase in
                if phase == .ready, !autoPlayed {
                    autoPlayed = true
                    coordinator.play(job)
                }
            }
            .onAppear {
                if job.phase == .ready, !autoPlayed {
                    autoPlayed = true
                    coordinator.play(job)
                }
            }
        }
    }
}
