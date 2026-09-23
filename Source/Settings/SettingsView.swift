import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Key.resolution) private var resolution = AppSettings.Default.resolution
    @AppStorage(AppSettings.Key.showAdult) private var showAdult = AppSettings.Default.showAdult
    @AppStorage(AppSettings.Key.keepAlive) private var keepAlive = AppSettings.Default.keepAlive
    @AppStorage(AppSettings.Key.mpvVerbose) private var mpvVerbose = AppSettings.Default.mpvVerbose
    @AppStorage(AppSettings.Key.audioLanguages) private var audioLanguages = AppSettings.Default.audioLanguages
    @AppStorage(AppSettings.Key.subtitleLanguages) private var subtitleLanguages = AppSettings.Default.subtitleLanguages
    @AppStorage(AppSettings.Key.seekShort) private var seekShort = AppSettings.Default.seekShort
    @AppStorage(AppSettings.Key.seekLong) private var seekLong = AppSettings.Default.seekLong
    @AppStorage(AppSettings.Key.torrentDHT) private var torrentDHT = AppSettings.Default.torrentDHT
    @AppStorage(AppSettings.Key.torrentNATPMP) private var torrentNATPMP = AppSettings.Default.torrentNATPMP
    @AppStorage(AppSettings.Key.uploadLimitKB) private var uploadLimitKB = AppSettings.Default.uploadLimitKB

    @ObservedObject private var engine = TorrentEngine.shared
    @State private var storage: Int64?
    @State private var confirmDeleteAll = false
    @State private var storageMessage: String?

    /// 動作確認用: Blender Foundation の Sintel（CC BY 3.0）。LibtorrentKit の検証用と同じトレント
    private let sintel = TorrentResultItem(
        manualTitle: "Sintel（Blender Foundation, CC BY 3.0）",
        link: "https://webtorrent.io/torrents/sintel.torrent",
        hash: "08ada5a7a6183aae1e09d831df6748d566095a10"
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("検索") {
                    Picker("既定の画質", selection: $resolution) {
                        ForEach(["2160", "1080", "720", "540", "480", ""], id: \.self) { r in
                            Text(r.isEmpty ? "指定なし" : "\(r)p").tag(r)
                        }
                    }
                    Toggle("成人向けの作品・拡張を含める", isOn: $showAdult)
                }

                Section {
                    LabeledContent("音声の優先言語") {
                        TextField("jpn,ja", text: $audioLanguages).multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("字幕の優先言語") {
                        TextField("jpn,ja,eng,en", text: $subtitleLanguages).multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    Picker("短いシーク", selection: $seekShort) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Picker("長いシーク（OP/ED スキップ）", selection: $seekLong) {
                        ForEach([60, 75, 85, 90, 120], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                } header: {
                    Text("再生")
                } footer: {
                    Text("言語は mpv の alang / slang 形式（カンマ区切り）。次に再生を始めたときから反映されます。")
                }

                Section {
                    Toggle("DHT", isOn: $torrentDHT)
                    Toggle("NAT-PMP（ポート開放）", isOn: $torrentNATPMP)
                    Stepper(value: $uploadLimitKB, in: 0...10_240, step: 64) {
                        Text(uploadLimitKB == 0 ? "アップロード上限: なし" : "アップロード上限: \(uploadLimitKB) KB/s")
                    }
                } header: {
                    Text("トレント")
                } footer: {
                    Text("DHT / NAT-PMP はアプリの再起動後に反映されます。アップロード上限は次に追加するトレントから反映されます。")
                }

                Section {
                    Toggle("バックグラウンドでも続ける", isOn: $keepAlive)
                        .onChange(of: keepAlive) { _, _ in engine.refreshKeepAlive() }
                } header: {
                    Text("バックグラウンド")
                } footer: {
                    Text("ダウンロード中・再生中は無音のオーディオを流してアプリが止まらないようにします。電池の消費が増えます。")
                }

                Section {
                    LabeledContent("ダウンロード済み", value: storage.map { Fmt.bytes($0) } ?? "計算中…")
                    Button("ダウンロード済みファイルをすべて削除", role: .destructive) { confirmDeleteAll = true }
                    if let storageMessage {
                        Text(storageMessage).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("ストレージ")
                } footer: {
                    Text("保存先: 「ファイル」アプリ → このiPad/iPhone内 → Nagare → Torrents")
                }

                Section {
                    Button {
                        PlaybackCoordinator.shared.open(sintel, episode: nil, mediaTitle: "Sintel（テスト再生）")
                    } label: {
                        Label("テスト再生（Sintel / CC BY 3.0）", systemImage: "play.rectangle")
                    }
                } header: {
                    Text("動作確認")
                } footer: {
                    Text("拡張機能を使わずに、トレント取得 → ストリーミング → mpv 再生の流れだけを確認します（約 130MB の公開トレント）。")
                }

                Section("診断") {
                    LabeledContent("バージョン", value: "\(RuntimeInfo.version) (\(RuntimeInfo.build))")
                    LabeledContent("Bundle ID（実行時）") {
                        Text(RuntimeInfo.bundleID).font(.caption).textSelection(.enabled)
                    }
                    LabeledContent("OpenSSL") {
                        Text(RuntimeInfo.openSSLVersion()).font(.caption)
                    }
                    LabeledContent("SSL_CTX_new の所在") {
                        Text(RuntimeInfo.symbolOwner("SSL_CTX_new")).font(.caption)
                    }
                    LabeledContent("ストリーミングサーバ") {
                        Text(StreamServer.shared.port == 0 ? "未起動" : "127.0.0.1:\(StreamServer.shared.port)").font(.caption)
                    }
                    Toggle("mpv の詳細ログ", isOn: $mpvVerbose)
                }

                Section("このアプリについて") {
                    Text("Nagare は Shiru（GPL-3.0）の設計と拡張機能の仕組みを元に、SwiftUI で書き直した iOS / iPadOS 向けアプリです。")
                        .font(.callout)
                    Text("使用ライブラリ: LibtorrentKit（BSD-3-Clause, libtorrent / Boost / OpenSSL を含む）、MPVKit（LGPL: mpv / FFmpeg / libass ほか）。詳しくはリポジトリの docs/LICENSES.md を参照してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .task { await refreshStorage() }
            .confirmationDialog("ダウンロード済みファイルをすべて削除しますか？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if engine.deleteAllDownloads() {
                        storageMessage = nil
                    } else {
                        storageMessage = "「トレント」タブの一覧を空にしてから実行してください"
                    }
                    Task { await refreshStorage() }
                }
            }
        }
    }

    private func refreshStorage() async {
        storage = engine.storageUsage()
    }
}
