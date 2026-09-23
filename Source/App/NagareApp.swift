import SwiftUI

@main
struct NagareApp: App {
    init() {
        RuntimeInfo.logStartup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @ObservedObject private var coordinator = PlaybackCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("検索", systemImage: "magnifyingglass") {
                SearchView()
            }
            Tab("トレント", systemImage: "arrow.down.circle") {
                TorrentsView()
            }
            Tab("拡張機能", systemImage: "puzzlepiece.extension") {
                ExtensionsView()
            }
            Tab("ログ", systemImage: "doc.text.magnifyingglass") {
                LogView()
            }
            Tab("設定", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .background(ExtensionHostAnchor().frame(width: 1, height: 1).allowsHitTesting(false))
        .sheet(item: $coordinator.preparingJob, onDismiss: { coordinator.sheetDidDismiss() }) { job in
            PlaybackPrepView(job: job)
        }
        .fullScreenCover(item: $coordinator.playing) { item in
            PlayerScreen(job: item.job, url: item.url, onClose: coordinator.closePlayer)
        }
        .task {
            await ExtensionManager.shared.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            qlog(.debug, "app", "scenePhase: \(String(describing: phase))")
        }
    }
}
