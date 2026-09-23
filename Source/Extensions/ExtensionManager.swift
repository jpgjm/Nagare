import Foundation
import CryptoKit

/// 拡張機能の追加・保存・読み込み（Shiru の extensions/manager.js 相当）。
/// 対応するソース指定: https://…/index.json、gh:ユーザー/リポジトリ/パス、npm:パッケージ
/// （Shiru と同じく gh:/npm: は esm.sh 経由で取得する）。
@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    struct Repository: Identifiable, Hashable {
        let url: String
        let entries: [String]
        var id: String { url }
    }

    @Published private(set) var sources: [ExtensionSource] = []
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var states: [String: ExtensionState] = [:]
    @Published private(set) var runtime: [String: ExtensionRuntimeStatus] = [:]

    private var bootstrapped = false

    private struct StoreFile: Codable {
        var sources: [JSONValue]
        var repositories: [String: [String]]
        var states: [String: ExtensionState]
    }

    private var storeURL: URL { AppSettings.appSupport.appendingPathComponent("extensions.json") }
    private var codeCacheDir: URL {
        let url = AppSettings.cachesDirectory.appendingPathComponent("ExtensionCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {
        loadStore()
    }

    // MARK: - 保存

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL) else {
            qlog(.info, "ext", "拡張の保存ファイルなし（初回）")
            return
        }
        do {
            let file = try JSONDecoder().decode(StoreFile.self, from: data)
            sources = file.sources.map { ExtensionSource(key: ExtensionSource.makeKey($0), config: $0) }
            repositories = file.repositories.map { Repository(url: $0.key, entries: $0.value) }.sorted { $0.url < $1.url }
            states = file.states
            for s in sources { runtime[s.key] = (states[s.key]?.enabled ?? false) ? .loading : .disabled }
            qlog(.info, "ext", "拡張を復元: \(sources.count) 件（有効 \(states.values.filter(\.enabled).count) 件）, リポジトリ \(repositories.count) 件")
        } catch {
            qlog(.error, "ext", "拡張の保存ファイルを読めません: \(error.localizedDescription)")
        }
    }

    private func saveStore() {
        let file = StoreFile(
            sources: sources.map(\.config),
            repositories: Dictionary(uniqueKeysWithValues: repositories.map { ($0.url, $0.entries) }),
            states: states
        )
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            qlog(.error, "ext", "拡張の保存に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 起動時

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await ExtensionHost.shared.waitUntilReady()
        for source in sources where states[source.key]?.enabled == true {
            await loadExtension(source)
        }
    }

    func reloadAll(reason: String) async {
        qlog(.info, "ext", "拡張をすべて読み直します（\(reason)）")
        await ExtensionHost.shared.waitUntilReady()
        for source in sources where states[source.key]?.enabled == true {
            await loadExtension(source)
        }
    }

    // MARK: - 追加・削除

    /// ソースを追加する。失敗時はエラーメッセージを返す。
    func addSource(_ input: String) async -> String? {
        let url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "URL を入力してください" }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("gh:") || url.hasPrefix("npm:") else {
            return "対応していない形式です（https://…, gh:…, npm:… のいずれか）。ローカルファイルは未対応です"
        }
        qlog(.info, "ext", "ソースを追加: \(url)")
        let manifest: [JSONValue]
        do {
            manifest = try await ExtensionResolver.manifest(from: url)
        } catch {
            qlog(.error, "ext", "マニフェスト取得失敗: \(url): \(error.localizedDescription)")
            return "マニフェストを取得できません: \(error.localizedDescription)"
        }

        // リポジトリ一覧（main だけで update が無いエントリの配列）
        if !manifest.isEmpty, manifest.allSatisfy({ $0["main"] != nil && $0["update"] == nil }) {
            let entries = manifest.flatMap { $0["main"]?.stringList.prefix(1) ?? [] }
            repositories.removeAll { $0.url == url }
            repositories.append(Repository(url: url, entries: entries))
            repositories.sort { $0.url < $1.url }
            saveStore()
            qlog(.info, "ext", "リポジトリを登録: \(url)（\(entries.count) 件）")
            return nil
        }

        for entry in manifest {
            if let problem = ExtensionResolver.validateConfig(entry) {
                qlog(.error, "ext", "不正な拡張定義（\(url)）: \(problem)")
                return "拡張の定義が不正です: \(problem)"
            }
        }
        var added = 0
        for entry in manifest {
            let key = ExtensionSource.makeKey(entry)
            let source = ExtensionSource(key: key, config: entry)
            if let index = sources.firstIndex(where: { $0.key == key }) {
                sources[index] = source
            } else {
                sources.append(source)
                added += 1
            }
            if states[key] == nil {
                states[key] = ExtensionState(enabled: false, settings: defaults(for: source))
                runtime[key] = .disabled
            }
            qlog(.info, "ext", "拡張を登録: \(source.name) \(source.version)（\(key)）")
        }
        saveStore()
        qlog(.info, "ext", "\(manifest.count) 件の拡張を登録（新規 \(added) 件）")
        return nil
    }

    func removeSource(_ source: ExtensionSource) async {
        await ExtensionHost.shared.unload(key: source.key)
        sources.removeAll { $0.key == source.key }
        states[source.key] = nil
        runtime[source.key] = nil
        saveStore()
        qlog(.info, "ext", "拡張を削除: \(source.name)（\(source.key)）")
    }

    func removeRepository(_ repo: Repository) {
        repositories.removeAll { $0.url == repo.url }
        saveStore()
        qlog(.info, "ext", "リポジトリを削除: \(repo.url)")
    }

    func isInstalled(manifestURL: String) -> Bool {
        sources.contains { $0.updates.contains(manifestURL) }
    }

    private func defaults(for source: ExtensionSource) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: source.settingDefs.map { ($0.key, $0.defaultValue) })
    }

    // MARK: - 有効化・設定

    func setEnabled(_ source: ExtensionSource, _ enabled: Bool) async {
        var state = states[source.key] ?? ExtensionState(enabled: false, settings: defaults(for: source))
        state.enabled = enabled
        states[source.key] = state
        saveStore()
        if enabled {
            qlog(.info, "ext", "有効化: \(source.name)")
            await loadExtension(source)
        } else {
            qlog(.info, "ext", "無効化: \(source.name)")
            await ExtensionHost.shared.unload(key: source.key)
            runtime[source.key] = .disabled
        }
    }

    func setSetting(_ source: ExtensionSource, key: String, value: JSONValue) async {
        var state = states[source.key] ?? ExtensionState(enabled: false, settings: defaults(for: source))
        state.settings[key] = value
        states[source.key] = state
        saveStore()
        let isSecret = source.settingDefs.first { $0.key == key }?.secret ?? false
        qlog(.debug, "ext", "設定変更: \(source.name).\(key) = \(isSecret ? "（秘匿）" : value.jsonString())")
        if runtime[source.key] == .active {
            await ExtensionHost.shared.updateSettings(key: source.key, settings: settingsAny(source.key))
        }
    }

    func settingsAny(_ key: String) -> [String: Any] {
        (states[key]?.settings ?? [:]).mapValues(\.anyValue)
    }

    func retry(_ source: ExtensionSource) async {
        await loadExtension(source)
    }

    // MARK: - 読み込み

    private func loadExtension(_ source: ExtensionSource) async {
        runtime[source.key] = .loading
        let started = Date()
        let fetched: (code: String, base: URL?)
        do {
            fetched = try await ExtensionResolver.code(for: source)
            try? fetched.code.write(to: cacheURL(for: source.key), atomically: true, encoding: .utf8)
        } catch {
            if let cached = try? String(contentsOf: cacheURL(for: source.key), encoding: .utf8), !cached.isEmpty {
                qlog(.warn, "ext", "\(source.name): コードの取得に失敗したためキャッシュを使います（\(error.localizedDescription)）")
                fetched = (cached, nil)
            } else {
                runtime[source.key] = .failed("コードを取得できません: \(error.localizedDescription)")
                qlog(.error, "ext", "\(source.name): コードを取得できません: \(error.localizedDescription)")
                return
            }
        }
        let code = ExtensionResolver.rewriteImports(fetched.code, base: fetched.base)
        let result = await ExtensionHost.shared.load(key: source.key, code: code, settings: settingsAny(source.key))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if result.validated {
            runtime[source.key] = .active
            qlog(.info, "ext", "\(source.name): 読み込み完了（\(ms)ms, \(code.count) 文字）")
        } else {
            let message = (result.error ?? "不明なエラー") + (result.stub ? "（中身の無いスタブモジュールです）" : "")
            runtime[source.key] = .failed(message)
            qlog(.error, "ext", "\(source.name): 読み込み失敗（\(ms)ms）: \(message)")
        }
    }

    private func cacheURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return codeCacheDir.appendingPathComponent("\(digest).js")
    }

    // MARK: - 検索

    /// 検索対象になる拡張（有効で読み込み済み、成人向けは設定に従う）
    var searchableSources: [ExtensionSource] {
        sources.filter { source in
            states[source.key]?.enabled == true
                && source.type == "torrent"
                && (!source.nsfw || AppSettings.showAdult)
        }
    }
}

/// マニフェスト・コードの取得と URL 解決（Shiru の getManifest / getExtension / resolveUrl の移植）
enum ExtensionResolver {
    static let validSchemes = try! NSRegularExpression(pattern: "^(https?:|gh:|npm:|file:|extension:)")

    private static func isValidScheme(_ s: String) -> Bool {
        validSchemes.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func isCustomScheme(_ s: String) -> Bool {
        s.hasPrefix("gh:") || s.hasPrefix("npm:")
    }

    enum ResolveError: LocalizedError {
        case http(Int, String)
        case notJSON
        case unsupported(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code, let url): return "HTTP \(code)（\(url)）"
            case .notJSON: return "JSON ではありません"
            case .unsupported(let s): return "未対応の形式です: \(s)"
            case .empty: return "内容が空です"
            }
        }
    }

    static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    static func fetchData(_ urlString: String) async throws -> (Data, URL) {
        guard let url = URL(string: urlString) else { throw ResolveError.unsupported(urlString) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        // esm.sh は User-Agent を見てビルド対象を変える（Vary: User-Agent）。
        // WKWebView（Safari）向けのコードを受け取るため、Safari の UA で取りに行く。
        if url.host?.hasSuffix("esm.sh") == true {
            req.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        qlog(status >= 400 ? .warn : .debug, "ext-resolve", "GET \(urlString) → \(status)（\(data.count) bytes）")
        guard (200..<300).contains(status) else { throw ResolveError.http(status, urlString) }
        return (data, response.url ?? url)
    }

    /// gh:/npm: の後ろ（JS の new URL(url).pathname 相当）
    private static func pathname(_ s: String) -> String {
        if s.hasPrefix("gh:") { return String(s.dropFirst(3)) }
        if s.hasPrefix("npm:") { return String(s.dropFirst(4)) }
        return s
    }

    static func manifest(from url: String) async throws -> [JSONValue] {
        let fetchURL: String
        if url.hasPrefix("http") {
            fetchURL = url
        } else if isCustomScheme(url) {
            let base = "https://esm.sh\(url.hasPrefix("gh:") ? "/gh" : "")/\(pathname(url))"
            fetchURL = base.range(of: #"\.json(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil ? base : "\(base)/index.json"
        } else {
            throw ResolveError.unsupported(url)
        }
        let (data, _) = try await fetchData(fetchURL)
        guard let any = try? JSONSerialization.jsonObject(with: data) else { throw ResolveError.notJSON }
        var list: [JSONValue]
        switch JSONValue(any: any) {
        case .array(let a): list = a
        case .object(let o): list = [.object(o)]
        default: throw ResolveError.notJSON
        }
        list = resolve(manifest: list, sourceURL: url)
        return list
    }

    /// resolveUrl: main / update の相対パスを取得元に対して解決する
    static func resolve(manifest: [JSONValue], sourceURL: String) -> [JSONValue] {
        let baseDir: String
        if isCustomScheme(sourceURL) || sourceURL.hasSuffix("/") {
            baseDir = sourceURL
        } else if let r = sourceURL.range(of: #"/[^/]*\.json(\?.*)?$"#, options: .regularExpression) {
            baseDir = sourceURL.replacingCharacters(in: r, with: "/")
        } else if let slash = sourceURL.lastIndex(of: "/") {
            baseDir = String(sourceURL[...slash])
        } else {
            baseDir = sourceURL
        }

        func collapse(_ path: String) -> String {
            var prefix = ""
            if let m = path.range(of: #"^([a-z]+://|[a-z]+:)"#, options: [.regularExpression, .caseInsensitive]) {
                prefix = String(path[m])
            }
            var out: [String] = []
            for part in path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false) {
                if part == ".." { _ = out.popLast() } else if part != "." && !part.isEmpty { out.append(String(part)) }
            }
            return prefix + out.joined(separator: "/")
        }
        func join(_ base: String, _ relative: String) -> String {
            collapse((base.hasSuffix("/") ? base : base + "/") + relative)
        }
        func resolveOne(_ url: String) -> String {
            if url.isEmpty || isValidScheme(url) { return url }
            let relative = url.hasPrefix("./") ? String(url.dropFirst(2)) : url
            if isCustomScheme(sourceURL) {
                if url == "." { return baseDir.hasSuffix("/") ? String(baseDir.dropLast()) : baseDir }
                return join(baseDir, relative)
            }
            if url == "." { return baseDir.hasSuffix("/") ? String(baseDir.dropLast()) : baseDir }
            return URL(string: relative, relativeTo: URL(string: baseDir))?.absoluteURL.absoluteString ?? url
        }
        func resolveValue(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s): return .string(resolveOne(s))
            case .array(let a): return .array(a.map { $0.stringValue.map { JSONValue.string(resolveOne($0)) } ?? $0 })
            default: return v
            }
        }

        return manifest.map { entry in
            guard case .object(var o) = entry else { return entry }
            if let update = o["update"] { o["update"] = resolveValue(update) }
            if let main = o["main"] { o["main"] = resolveValue(main) }
            return .object(o)
        }
    }

    /// validateConfig の移植。問題があればその内容を返す
    static func validateConfig(_ config: JSONValue) -> String? {
        guard case .object(let o) = config else { return "オブジェクトではありません" }
        for prop in ["id", "name", "version", "main", "update", "type"] where o[prop] == nil {
            return "\(prop) がありません"
        }
        switch o["update"] {
        case .string: break
        case .array(let a) where a.allSatisfy({ if case .string = $0 { return true } else { return false } }): break
        default: return "update の形式が不正です"
        }
        if let settings = o["settings"]?.arrayValue {
            for s in settings {
                guard let def = ExtensionSettingDef(json: s) else { return "設定項目の形式が不正です" }
                if def.kind == .dropdown || def.kind == .multiselect {
                    if def.options.isEmpty { return "設定 \(def.key) の選択肢がありません" }
                    let valid = Set(def.options.map(\.value))
                    if def.kind == .dropdown, let d = s["default"], !valid.contains(d.stringValue ?? "") { return "設定 \(def.key) の既定値が選択肢にありません" }
                    if def.kind == .multiselect, let d = s["default"], !(d.arrayValue?.allSatisfy { valid.contains($0.stringValue ?? "") } ?? false) {
                        return "設定 \(def.key) の既定値が選択肢にありません"
                    }
                }
            }
        }
        return nil
    }

    /// 拡張のコードを取得する（getExtension の移植）。base は import の相対指定を解決する基準 URL
    static func code(for source: ExtensionSource) async throws -> (code: String, base: URL?) {
        let prefix = source.config["locale"]?.stringValue ?? source.updates.first ?? ""
        let mains = source.mains.map { main in
            main.isEmpty || isValidScheme(main) ? main : "\(prefix)/\(main)"
        }
        var lastError: Error = ResolveError.empty
        for main in mains {
            do {
                if main.hasPrefix("http") {
                    let (data, finalURL) = try await fetchData(main)
                    guard let code = String(data: data, encoding: .utf8), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResolveError.empty }
                    return (code, finalURL)
                }
                if isCustomScheme(main) {
                    let parts = pathname(main).split(separator: "/").map(String.init)
                    let isGH = main.hasPrefix("gh:")
                    guard parts.count >= (isGH ? 2 : 1) else { throw ResolveError.unsupported(main) }
                    let head = isGH ? "https://esm.sh/gh/\(parts[0])/\(parts[1])" : "https://esm.sh/\(parts[0])"
                    let rest = parts.dropFirst(isGH ? 2 : 1).joined(separator: "/")
                    let urlString = "\(head)/es2022/\(rest).mjs"
                    let (data, finalURL) = try await fetchData(urlString)
                    guard var code = String(data: data, encoding: .utf8) else { throw ResolveError.empty }
                    var base = finalURL
                    // esm.sh が再エクスポートだけのスタブを返したときは本体を取りに行く（Shiru と同じ）
                    if code.contains("export * from"), code.contains("export { default } from"),
                       let r = code.range(of: #"from\s+["']([^"']+)["']"#, options: .regularExpression) {
                        let spec = code[r].replacingOccurrences(of: #"^from\s+["']|["']$"#, with: "", options: .regularExpression)
                        let target = spec.hasPrefix("http") ? spec : "https://esm.sh\(spec)"
                        let (moduleData, moduleURL) = try await fetchData(target)
                        code = String(data: moduleData, encoding: .utf8) ?? code
                        base = moduleURL
                    }
                    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResolveError.empty }
                    return (code, base)
                }
                throw ResolveError.unsupported(main)
            } catch {
                qlog(.warn, "ext-resolve", "\(source.name): \(main) から取得できません: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// Blob URL から import() すると "./x" や "/x" が解決できないため、取得元 URL 基準の絶対 URL に書き換える
    static func rewriteImports(_ code: String, base: URL?) -> String {
        guard let base else { return code }
        let pattern = #"((?:\bfrom|\bimport)\s*\(?\s*)(["'])((?:\.{1,2}/|/)[^"'\n]*)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return code }
        let ns = code as NSString
        var result = ""
        var last = 0
        var count = 0
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let specRange = match.range(at: 3)
            let spec = ns.substring(with: specRange)
            guard let absolute = URL(string: spec, relativeTo: base)?.absoluteURL.absoluteString else { continue }
            result += ns.substring(with: NSRange(location: last, length: specRange.location - last))
            result += absolute
            last = specRange.location + specRange.length
            count += 1
        }
        result += ns.substring(from: last)
        if count > 0 { qlog(.debug, "ext-resolve", "import 指定を \(count) 件、絶対 URL に書き換え（基準 \(base.absoluteString)）") }
        return result
    }
}
