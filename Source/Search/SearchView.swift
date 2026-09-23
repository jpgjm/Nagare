import SwiftUI

/// AniList で作品を探す（ログイン不要）
struct SearchView: View {
    @State private var query = ""
    @State private var results: [AniMedia] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @AppStorage(AppSettings.Key.showAdult) private var showAdult = AppSettings.Default.showAdult

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !loading {
                    ContentUnavailableView {
                        Label(errorMessage == nil ? "作品を検索" : "検索できませんでした", systemImage: errorMessage == nil ? "magnifyingglass" : "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage ?? "作品名（日本語・ローマ字・英語）で AniList を検索します")
                    }
                } else {
                    List(results) { media in
                        NavigationLink(value: media.id) {
                            MediaRow(media: media)
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if loading { ProgressView() }
                    }
                }
            }
            .navigationTitle("検索")
            .navigationDestination(for: Int.self) { id in
                MediaDetailView(mediaID: id, preview: results.first { $0.id == id })
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "作品名")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                guard newValue.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    runSearch()
                }
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        loading = true
        errorMessage = nil
        Task {
            do {
                results = try await AniListClient.shared.search(text, includeAdult: showAdult)
                if results.isEmpty { errorMessage = "「\(text)」に一致する作品はありません" }
            } catch {
                errorMessage = error.localizedDescription
                qlog(.error, "search", "AniList 検索失敗: \(error.localizedDescription)")
            }
            loading = false
        }
    }
}

struct MediaRow: View {
    let media: AniMedia

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: media.coverURL)
                .frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(media.displayTitle).font(.headline).lineLimit(2)
                if !media.subtitle.isEmpty && media.subtitle != media.displayTitle {
                    Text(media.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(media.formatLabel)
                    if let season = media.seasonLabel { Text(season) }
                    Text(media.statusLabel)
                    if let eps = media.episodes { Text("全\(eps)話") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CoverImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(.quaternary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
