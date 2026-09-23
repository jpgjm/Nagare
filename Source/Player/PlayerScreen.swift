import SwiftUI
import AVFoundation

/// 全画面のプレイヤー
struct PlayerScreen: View {
    @ObservedObject var job: TorrentJob
    let url: URL
    let onClose: () -> Void

    @StateObject private var model = PlayerModel()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @AppStorage(AppSettings.Key.seekShort) private var seekShort = AppSettings.Default.seekShort
    @AppStorage(AppSettings.Key.seekLong) private var seekLong = AppSettings.Default.seekLong

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVPlayerView(url: url, model: model)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if model.isWaiting && model.errorMessage == nil {
                waitingOverlay
                    .allowsHitTesting(false)
            }

            if let error = model.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).multilineTextAlignment(.center)
                    Button("閉じる", action: close).buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .onAppear {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                try session.setActive(true)
            } catch {
                qlog(.warn, "player", "オーディオセッションを設定できません: \(error.localizedDescription)")
            }
            UIApplication.shared.isIdleTimerDisabled = true
            TorrentEngine.shared.isPlaying = true
            qlog(.info, "player", "表示: \(job.selectedFile?.path ?? job.title)")
            scheduleHide()
        }
        .onDisappear {
            // onDisappear は画面遷移の途中で一時的に呼ばれることがある（v1.0.1 で再生直後に
            // mpv が破棄された原因）。ここでは記録だけにして、破棄は「閉じる」操作と
            // ビューの解体（MPVPlayerView.dismantleUIViewController）で行う。
            qlog(.debug, "player", "onDisappear（mpv は維持）")
        }
        .onChange(of: model.paused) { _, paused in
            if paused { showControls = true } else { scheduleHide() }
        }
    }

    private var waitingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large).tint(.white)
            Text(model.fileLoaded ? "バッファ中…" : "読み込み中…")
            if let s = job.status {
                Text("\(Fmt.rate(s.downloadRate))・ピア \(s.connectedPeers)・\(Fmt.percent(s.progress))")
                    .font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // 上段
            HStack(alignment: .top, spacing: 12) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.title3.bold()).padding(10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.mediaTitle ?? job.title).font(.headline).lineLimit(1)
                    Text((job.selectedFile?.path as NSString?)?.lastPathComponent ?? job.title)
                        .font(.caption).lineLimit(1).opacity(0.8)
                    if let s = job.status {
                        Text("\(Fmt.rate(s.downloadRate))・ピア \(s.connectedPeers)・\(Fmt.percent(s.progress))・先読み \(Int(model.cacheSeconds)) 秒")
                            .font(.caption2.monospacedDigit()).opacity(0.8)
                    }
                }
                Spacer()
                trackMenus
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            // 中段
            HStack(spacing: 36) {
                Button { model.seek(by: -Double(seekShort)); scheduleHide() } label: {
                    Image(systemName: "gobackward.\(seekShort)").font(.system(size: 30))
                }
                Button { model.togglePause(); scheduleHide() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 44))
                }
                Button { model.seek(by: Double(seekShort)); scheduleHide() } label: {
                    Image(systemName: "goforward.\(seekShort)").font(.system(size: 30))
                }
            }

            Spacer()

            // 下段
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : model.timePos },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubValue = model.timePos
                            scrubbing = true
                            hideTask?.cancel()
                        } else {
                            model.seek(to: scrubValue)
                            scrubbing = false
                            scheduleHide()
                        }
                    }
                )
                .tint(.white)
                HStack {
                    Text(Fmt.duration(scrubbing ? scrubValue : model.timePos))
                    Spacer()
                    Button {
                        model.seek(by: -Double(seekLong)); scheduleHide()
                    } label: {
                        Label("\(seekLong)秒戻る", systemImage: "backward.end.alt")
                    }
                    Button {
                        model.seek(by: Double(seekLong)); scheduleHide()
                    } label: {
                        Label("OP/ED スキップ（+\(seekLong)秒）", systemImage: "forward.end.alt")
                    }
                    Spacer()
                    Text(Fmt.duration(model.duration))
                }
                .font(.caption.monospacedDigit())
                .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var trackMenus: some View {
        HStack(spacing: 4) {
            Menu {
                Button {
                    model.selectSubtitle(nil)
                } label: {
                    if model.currentSid == "no" { Label("オフ", systemImage: "checkmark") } else { Text("オフ") }
                }
                ForEach(model.subtitleTracks) { t in
                    Button {
                        model.selectSubtitle(t.id)
                    } label: {
                        if model.currentSid == String(t.id) { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble").font(.title3).padding(8)
            }
            Menu {
                ForEach(model.audioTracks) { t in
                    Button {
                        model.selectAudio(t.id)
                    } label: {
                        if model.currentAid == String(t.id) { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                    }
                }
            } label: {
                Image(systemName: "waveform").font(.title3).padding(8)
            }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { v in
                    Button {
                        model.setSpeed(v)
                    } label: {
                        if abs(model.speed - v) < 0.01 { Label("\(v, specifier: "%.2g")x", systemImage: "checkmark") } else { Text("\(v, specifier: "%.2g")x") }
                    }
                }
            } label: {
                Image(systemName: "speedometer").font(.title3).padding(8)
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !model.paused, !scrubbing else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    private func close() {
        hideTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        TorrentEngine.shared.isPlaying = false
        model.shutdown()
        qlog(.info, "player", "プレイヤーを閉じました")
        onClose()
    }
}
