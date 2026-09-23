import SwiftUI

/// 作品の詳細と話数の選択
struct MediaDetailView: View {
    let mediaID: Int
    let preview: AniMedia?

    @State private var media: AniMedia?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var episode = 1
    @State private var includeBatch = false
    @State private var includeMovie = false
    @State private var resolution = AppSettings.resolution
    @State private var showAllDescription = false

    private var current: AniMedia? { media ?? preview }

    var body: some View {
        List {
            if let m = current {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        CoverImage(url: m.coverURL).frame(width: 100, height: 142)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.displayTitle).font(.title3.bold())
                            if !m.subtitle.isEmpty && m.subtitle != m.displayTitle {
                                Text(m.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text([m.formatLabel, m.seasonLabel, m.statusLabel, m.episodes.map { "全\($0)話" }].compactMap { $0 }.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let score = m.averageScore {
                                Text("スコア \(score)").font(.caption).foregroundStyle(.secondary)
                            }
                            if !m.genres.isEmpty {
                                Text(m.genres.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let d = m.descriptionText, !d.isEmpty {
                        Text(Self.stripHTML(d))
                            .font(.callout)
                            .lineLimit(showAllDescription ? nil : 4)
                            .onTapGesture { showAllDescription.toggle() }
                    }
                }

                if m.isMovie {
                    Section("映画") {
                        Text("映画は話数の指定なしで検索します").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        let maxEp = max(m.playableEpisodes, 1)
                        Stepper(value: $episode, in: 1...max(m.maxEpisode, maxEp, 1)) {
                            Text("第 \(episode) 話")
                                .font(.headline.monospacedDigit())
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(1...maxEp, id: \.self) { ep in
                                    Button {
                                        episode = ep
                                    } label: {
                                        Text("\(ep)")
                                            .font(.callout.monospacedDigit())
                                            .frame(minWidth: 36, minHeight: 32)
                                            .background(ep == episode ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                            .foregroundStyle(ep == episode ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("話数")
                    } footer: {
                        Text("放送済み: \(m.playableEpisodes) 話" + (m.maxEpisode > m.playableEpisodes ? "（予定 \(m.maxEpisode) 話）" : ""))
                    }
                }

                Section("検索オプション") {
                    Picker("画質", selection: $resolution) {
                        ForEach(["2160", "1080", "720", "540", "480", ""], id: \.self) { r in
                            Text(r.isEmpty ? "指定なし" : "\(r)p").tag(r)
                        }
                    }
                    Toggle("まとめ（バッチ）も探す", isOn: $includeBatch)
                    Toggle("映画として探す", isOn: $includeMovie)
                }

                Section {
                    NavigationLink {
                        TorrentResultsView(
                            media: m,
                            episode: m.isMovie ? nil : episode,
                            resolution: resolution,
                            batch: includeBatch,
                            movie: includeMovie
                        )
                    } label: {
                        Label("拡張機能でトレントを探す", systemImage: "magnifyingglass")
                            .font(.headline)
                    }
                    .disabled(media == nil)
                    if media == nil && loading {
                        HStack { ProgressView(); Text("作品情報を取得中…").foregroundStyle(.secondary) }
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("再試行") { Task { await load() } }
                }
            }
        }
        .navigationTitle(current?.displayTitle ?? "作品")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let m = try await AniListClient.shared.media(id: mediaID)
            media = m
            if !m.isMovie {
                episode = min(max(1, m.playableEpisodes), max(m.maxEpisode, 1))
                if m.status == "FINISHED" { episode = 1 }
            }
            includeMovie = m.isMovie
            includeBatch = m.status == "FINISHED" && (m.episodes ?? 0) > 1
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
    }
}
