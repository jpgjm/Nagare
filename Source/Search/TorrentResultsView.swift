import SwiftUI

@MainActor
final class TorrentResultsModel: ObservableObject {
    enum SourceState: Equatable {
        case waiting
        case done(Int)
        case failed(String)
        case skipped(String)
    }

    struct SourceRow: Identifiable {
        let key: String
        let name: String
        var state: SourceState
        var errors: [String]
        var id: String { key }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case seeders, newest, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .seeders: return "シーダー順"
            case .newest: return "新しい順"
            case .size: return "サイズ順"
            }
        }
    }

    @Published var rows: [SourceRow] = []
    @Published var results: [TorrentResultItem] = []
    @Published var running = false
    @Published var querySummary = ""
    /// ani.zip から得た通し番号（バッチの中から話を選ぶときの手がかり）
    @Published var absoluteEpisode: Int?
    @Published var sort: SortOrder = .seeders

    private var started = false

    var sortedResults: [TorrentResultItem] {
        switch sort {
        case .seeders:
            return results.sorted {
                if $0.accuracyRank != $1.accuracyRank { return $0.accuracyRank > $1.accuracyRank }
                return $0.seeders > $1.seeders
            }
        case .newest:
            return results.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .size:
            return results.sorted { $0.size > $1.size }
        }
    }

    func run(media: AniMedia, episode: Int?, resolution: String, batch: Bool, movie: Bool, force: Bool = false) async {
        guard force || !started else { return }
        started = true
        running = true
        results = []
        let manager = ExtensionManager.shared
        let sources = manager.searchableSources
        rows = sources.map { SourceRow(key: $0.key, name: $0.name, state: .waiting, errors: []) }
        guard !sources.isEmpty else {
            running = false
            qlog(.warn, "search", "有効な拡張がありません")
            return
        }

        let built = await QueryBuilder.build(media: media, episode: episode, resolution: resolution)
        querySummary = built.summary
        absoluteEpisode = (built.options["absoluteEpisode"] as? Double).map { Int($0) } ?? (built.options["absoluteEpisode"] as? Int)
        qlog(.info, "search", "\(sources.count) 個の拡張で検索開始（batch=\(batch), movie=\(movie)）")

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    await self.query(source, options: built.options, batch: batch, movie: movie)
                }
            }
        }
        running = false
        qlog(.info, "search", "検索完了: \(results.count) 件（重複除去後）")
    }

    private func query(_ source: ExtensionSource, options: [String: Any], batch: Bool, movie: Bool) async {
        let manager = ExtensionManager.shared
        if manager.runtime[source.key] != .active {
            // 起動直後などで未読み込みなら読み込みを待つ
            if manager.runtime[source.key] == .loading || manager.runtime[source.key] == nil {
                for _ in 0..<60 where manager.runtime[source.key] == .loading {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if manager.runtime[source.key] != .active {
                var reason = "読み込まれていません"
                if case .failed(let m)? = manager.runtime[source.key] { reason = m }
                update(source.key) { $0.state = .skipped(reason) }
                qlog(.warn, "search", "\(source.name): スキップ（\(reason)）")
                return
            }
        }
        let started = Date()
        let result = await ExtensionHost.shared.query(key: source.key, extensionName: source.name, options: options, batch: batch, movie: movie)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        merge(result.results)
        update(source.key) {
            $0.errors = result.errors
            $0.state = result.results.isEmpty && !result.errors.isEmpty ? .failed(result.errors.joined(separator: " / ")) : .done(result.results.count)
        }
        let breakdown = Dictionary(grouping: result.results, by: \.searchType).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        if let top = result.results.first {
            qlog(.debug, "search", "\(source.name): 先頭の結果「\(top.title)」")
        }
        if result.errors.isEmpty {
            qlog(.info, "search", "\(source.name): \(result.results.count) 件（\(breakdown), \(ms)ms）")
        } else {
            qlog(.warn, "search", "\(source.name): \(result.results.count) 件（\(ms)ms）, エラー: \(result.errors.joined(separator: " / "))")
        }
    }

    private func update(_ key: String, _ change: (inout SourceRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        change(&rows[i])
    }

    /// Shiru の dedupeResults と同じく hash で重複をまとめる（シーダー等は大きい方）
    private func merge(_ items: [TorrentResultItem]) {
        var merged = results
        for item in items {
            if let i = merged.firstIndex(where: { $0.id == item.id }) {
                var existing = merged[i]
                for (k, n) in zip(item.extensionKeys, item.extensionNames) where !existing.extensionKeys.contains(k) {
                    existing.extensionKeys.append(k)
                    existing.extensionNames.append(n)
                }
                if item.seeders > existing.seeders || item.accuracyRank > existing.accuracyRank {
                    var better = item
                    better.extensionKeys = existing.extensionKeys
                    better.extensionNames = existing.extensionNames
                    merged[i] = better
                } else {
                    merged[i] = existing
                }
            } else {
                merged.append(item)
            }
        }
        results = merged
    }
}

struct TorrentResultsView: View {
    let media: AniMedia
    let episode: Int?
    let resolution: String
    let batch: Bool
    let movie: Bool

    @StateObject private var model = TorrentResultsModel()
    @ObservedObject private var manager = ExtensionManager.shared
    @State private var showManual = false
    @State private var manualLink = ""

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        switch row.state {
                        case .waiting: ProgressView()
                        case .done(let n): Text("\(n) 件").foregroundStyle(.secondary)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.orange)
                        }
                    }
                    if case .failed(let m) = row.state {
                        Text(m).font(.caption).foregroundStyle(.red)
                    } else if case .skipped(let m) = row.state {
                        Text(m).font(.caption).foregroundStyle(.orange)
                    } else if !row.errors.isEmpty {
                        Text(row.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                    }
                }
                if model.rows.isEmpty && !model.running {
                    Text("有効な拡張機能がありません。「拡張機能」タブで追加・有効化してください。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("拡張機能")
            } footer: {
                if !model.querySummary.isEmpty {
                    Text(model.querySummary).font(.caption2)
                }
            }

            Section {
                if model.results.isEmpty {
                    if model.running {
                        HStack { ProgressView(); Text("検索中…").foregroundStyle(.secondary) }
                    } else if !model.rows.isEmpty {
                        Text("見つかりませんでした").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.sortedResults) { item in
                    Button {
                        PlaybackCoordinator.shared.open(item, episode: episode, absoluteEpisode: model.absoluteEpisode, mediaTitle: media.displayTitle)
                    } label: {
                        ResultRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = item.link
                        } label: {
                            Label("リンクをコピー", systemImage: "doc.on.doc")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("結果 \(model.results.count) 件")
                    Spacer()
                    Picker("並び順", selection: $model.sort) {
                        ForEach(TorrentResultsModel.SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                }
            }
        }
        .navigationTitle(episode.map { "第\($0)話のトレント" } ?? "トレント")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showManual = true
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .accessibilityLabel("magnet / .torrent URL を直接開く")
                Button {
                    Task { await model.run(media: media, episode: episode, resolution: resolution, batch: batch, movie: movie, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.running)
            }
        }
        .alert("magnet / .torrent URL を開く", isPresented: $showManual) {
            TextField("magnet:?xt=… または https://…", text: $manualLink)
            Button("開く") {
                let link = manualLink.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !link.isEmpty else { return }
                let hash = TorrentResultItem.infoHash(fromMagnet: link) ?? ""
                PlaybackCoordinator.shared.open(TorrentResultItem(manualTitle: link, link: link, hash: hash), episode: episode, mediaTitle: media.displayTitle)
                manualLink = ""
            }
            Button("キャンセル", role: .cancel) {}
        }
        .task {
            await model.run(media: media, episode: episode, resolution: resolution, batch: batch, movie: movie)
        }
    }
}

private struct ResultRow: View {
    let item: TorrentResultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.subheadline).lineLimit(3)
            HStack(spacing: 10) {
                Label("\(item.seeders)", systemImage: "arrow.up.circle").foregroundStyle(item.seeders > 0 ? .green : .secondary)
                Label("\(item.leechers)", systemImage: "arrow.down.circle")
                if item.size > 0 { Text(Fmt.bytes(item.size)) }
                if let d = item.date { Text(Fmt.relative(d)) }
                if item.isBatch { Text("まとめ").padding(.horizontal, 4).background(.purple.opacity(0.2), in: Capsule()) }
                if item.accuracy == "high" { Text("高精度").padding(.horizontal, 4).background(.green.opacity(0.2), in: Capsule()) }
                if item.type == "best" { Text("ベスト").padding(.horizontal, 4).background(.yellow.opacity(0.25), in: Capsule()) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            Text(item.extensionNames.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
