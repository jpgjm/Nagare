import SwiftUI

struct TorrentsView: View {
    @ObservedObject private var engine = TorrentEngine.shared

    var body: some View {
        NavigationStack {
            List {
                if let error = engine.sessionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                if engine.jobs.isEmpty {
                    ContentUnavailableView("トレントはありません", systemImage: "arrow.down.circle",
                                           description: Text("検索結果から開いたトレントがここに表示されます。アプリを終了すると一覧は消えます（ファイルは残ります）。"))
                }
                ForEach(engine.jobs) { job in
                    JobRow(job: job)
                }
            }
            .navigationTitle("トレント")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: TorrentJob
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.selectedFile.map { ($0.path as NSString).lastPathComponent } ?? job.title)
                .font(.subheadline).lineLimit(2)
            if let s = job.status {
                ProgressView(value: s.progress)
                HStack(spacing: 10) {
                    Text(Fmt.percent(s.progress))
                    Text("↓\(Fmt.rate(s.downloadRate))")
                    Text("↑\(Fmt.rate(s.uploadRate))")
                    Text("ピア \(s.connectedPeers)")
                    Spacer()
                    Text(job.completed ? "完了" : (s.isPaused ? "一時停止" : job.phase.label))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(job.phase.label).font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let m) = job.phase {
                Text(m).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                if job.phase == .ready {
                    Button {
                        PlaybackCoordinator.shared.play(job)
                    } label: {
                        Label("再生", systemImage: "play.fill")
                    }
                }
                if job.phase == .choosingFile || job.phase == .ready || job.phase == .fetchingMetadata {
                    Button {
                        PlaybackCoordinator.shared.showPreparation(job)
                    } label: {
                        Label(job.phase == .choosingFile ? "ファイルを選ぶ" : "詳細", systemImage: "list.bullet")
                    }
                }
                if let s = job.status, !job.completed {
                    Button {
                        Task {
                            if s.isPaused { await TorrentEngine.shared.resume(job) } else { await TorrentEngine.shared.pause(job) }
                        }
                    } label: {
                        Label(s.isPaused ? "再開" : "一時停止", systemImage: s.isPaused ? "play.circle" : "pause.circle")
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 4)
        .confirmationDialog("このトレントを削除しますか？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("一覧から外す（ファイルは残す）") {
                Task { await TorrentEngine.shared.remove(job, deleteFiles: false) }
            }
            Button("ファイルも削除", role: .destructive) {
                Task { await TorrentEngine.shared.remove(job, deleteFiles: true) }
            }
        }
    }
}
