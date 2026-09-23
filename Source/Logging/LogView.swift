import SwiftUI
import Combine

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    private var cancellable: AnyCancellable?

    init() {
        entries = AppLog.shared.snapshot()
        cancellable = AppLog.shared.updates
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.entries = AppLog.shared.snapshot()
            }
    }
}

struct LogView: View {
    @StateObject private var store = LogStore()
    @State private var minimumLevel: LogLevel = .debug
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var followTail = true

    private var filtered: [LogEntry] {
        store.entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            if searchText.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("重要度", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text("\(level.japanese)以上").tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                ScrollViewReader { proxy in
                    List(filtered) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = entry.line
                                } label: {
                                    Label("この行をコピー", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    .listStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: store.entries.count) { _, _ in
                        guard followTail, let last = filtered.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "ログを検索")
            .navigationTitle("ログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        followTail.toggle()
                    } label: {
                        Image(systemName: followTail ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                    }
                    .accessibilityLabel("末尾に追従")

                    Menu {
                        Button {
                            do {
                                exportURL = try AppLog.shared.exportFile(entries: filtered)
                                qlog(.info, "log", "ログを書き出し: \(filtered.count) 行")
                            } catch {
                                exportError = error.localizedDescription
                            }
                        } label: {
                            Label("表示中のログを書き出す", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = filtered.map(\.line).joined(separator: "\n")
                        } label: {
                            Label("表示中のログをコピー", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            AppLog.shared.clearMemory()
                        } label: {
                            Label("画面のログを消去（ファイルは残る）", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(get: { exportURL.map(ShareItem.init) }, set: { exportURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .alert("書き出しに失敗しました", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var color: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(AppLog.timestampFormatter.string(from: entry.date).suffix(12))
                Text(entry.level.label).bold().foregroundStyle(color)
                Text(entry.category).foregroundStyle(.teal)
            }
            .font(.system(.caption2, design: .monospaced))
            Text(entry.message)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
