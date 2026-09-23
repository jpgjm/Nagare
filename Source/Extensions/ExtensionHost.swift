import Foundation
import WebKit
import SwiftUI

/// 拡張機能（Shiru 互換の ES モジュール）を動かす隠し WKWebView。
/// Shiru の worker.js に相当する処理は Resources/Bundle/extension-host.html にある。
@MainActor
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()

    struct LoadResult {
        let validated: Bool
        let error: String?
        let stub: Bool
    }

    struct QueryResult {
        let results: [TorrentResultItem]
        let errors: [String]
    }

    private(set) var webView: WKWebView!
    private let fetchHandler = ExtensionFetchHandler()
    private let logHandler = ExtensionLogHandler()
    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var userAgent: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = .shared
        // 拡張の検索結果を URL キャッシュで取り違えないよう、キャッシュは使わない
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        fetchHandler.host = self
        controller.addScriptMessageHandler(fetchHandler, contentWorld: .page, name: "nagareFetch")
        controller.add(logHandler, contentWorld: .page, name: "nagareLog")
        config.userContentController = controller
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self
        webView.isInspectable = true
        loadPage()
    }

    private func loadPage() {
        guard let url = Bundle.main.url(forResource: "extension-host", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            qlog(.error, "ext-host", "extension-host.html がバンドルにありません")
            return
        }
        qlog(.info, "ext-host", "拡張ランタイムを読み込み中")
        webView.loadHTMLString(html, baseURL: URL(string: "https://extensions.nagare.invalid/"))
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { cont in
            readyWaiters.append(cont)
        }
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            self?.userAgent = value as? String
        }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
        qlog(.info, "ext-host", "拡張ランタイムの準備ができました")
    }

    // MARK: - JS 呼び出し

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> JSONValue {
        await waitUntilReady()
        let value: Any = try await withCheckedThrowingContinuation { cont in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        guard let text = value as? String, let data = text.data(using: .utf8) else {
            return .null
        }
        return JSONValue(any: try? JSONSerialization.jsonObject(with: data))
    }

    func load(key: String, code: String, settings: [String: Any]) async -> LoadResult {
        do {
            let json = try await call("return await window.__nagare.load(id, code, settings)",
                                      ["id": key, "code": code, "settings": settings])
            let validated = json["validated"]?.boolValue ?? false
            return LoadResult(validated: validated, error: json["error"]?.stringValue, stub: json["stub"]?.boolValue ?? false)
        } catch {
            return LoadResult(validated: false, error: "ランタイムの呼び出しに失敗: \(error.localizedDescription)", stub: false)
        }
    }

    func validate(key: String) async -> LoadResult {
        do {
            let json = try await call("return await window.__nagare.validate(id)", ["id": key])
            return LoadResult(validated: json["validated"]?.boolValue ?? false, error: json["error"]?.stringValue, stub: false)
        } catch {
            return LoadResult(validated: false, error: error.localizedDescription, stub: false)
        }
    }

    func updateSettings(key: String, settings: [String: Any]) async {
        _ = try? await call("return window.__nagare.updateSettings(id, settings)", ["id": key, "settings": settings])
    }

    func unload(key: String) async {
        _ = try? await call("return window.__nagare.unload(id)", ["id": key])
    }

    func query(key: String, extensionName: String, options: [String: Any], batch: Bool, movie: Bool) async -> QueryResult {
        do {
            let json = try await call("return await window.__nagare.query(id, options, types)",
                                      ["id": key, "options": options, "types": ["batch": batch, "movie": movie]])
            let raw = json["results"]?.arrayValue ?? []
            let items = raw.compactMap { TorrentResultItem(json: $0, extensionKey: key, extensionName: extensionName) }
            let errors = json["errors"]?.stringList ?? []
            return QueryResult(results: items, errors: errors)
        } catch {
            return QueryResult(results: [], errors: ["ランタイムの呼び出しに失敗: \(error.localizedDescription)"])
        }
    }

    // MARK: - ネイティブ fetch

    /// RFC 3986 で許されない文字（| や " など）を UTF-8 でパーセントエンコードした URL を作る。
    /// 既存の %XX はそのまま残す。ブラウザの URL（WHATWG）は | を生のまま残すが、
    /// iOS の URL(string:) はそれを「寛容に」受け入れたうえで通信層での扱いが不定になるため、
    /// ここで厳密な形にしてから URLSession に渡す（v1.0.2 で Nyaa の検索語が効かなかった件の対策）。
    static func strictURL(_ string: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#@!$&'()*+,;=%")
        var out = ""
        out.reserveCapacity(string.utf8.count)
        let scalars = Array(string.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "%" {
                // 正しい %XX だけを残し、それ以外の % は %25 にする
                if i + 2 < scalars.count,
                   scalars[i + 1].properties.isASCIIHexDigit, scalars[i + 2].properties.isASCIIHexDigit {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += "%25"
                }
            } else if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    out += String(format: "%%%02X", byte)
                }
            }
            i += 1
        }
        return URL(string: out)
    }

    /// 送信した URL をログ用に整える（key / token / pass などを含む名前の値は伏せる、長すぎる分は切る）
    static func redactedQueryURL(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        comps.queryItems = comps.queryItems?.map { item in
            let name = item.name.lowercased()
            let secret = ["key", "token", "pass", "auth", "secret", "sig", "cookie"].contains { name.contains($0) }
            return secret ? URLQueryItem(name: item.name, value: "***") : item
        }
        let text = (comps.url?.absoluteString ?? url.absoluteString).removingPercentEncoding ?? url.absoluteString
        return text.count > 4000 ? String(text.prefix(4000)) + "…（\(text.count) 文字）" : text
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 520...530: return "Cloudflare Error"
        default: return ""
        }
    }

    func performFetch(_ body: [String: Any]) async -> [String: Any] {
        guard let urlString = body["url"] as? String, let url = Self.strictURL(urlString) else {
            return ["error": "URL が不正です"]
        }
        if url.absoluteString != urlString {
            qlog(.debug, "ext-fetch", "URL を正規化（RFC 3986 で使えない文字をエンコード、\(urlString.count) → \(url.absoluteString.count) 文字）")
        }
        let method = (body["method"] as? String) ?? "GET"
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let headers = body["headers"] as? [String: Any] {
            for (k, v) in headers {
                request.setValue("\(v)", forHTTPHeaderField: k)
            }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil, let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let b64 = body["body"] as? String, let data = Data(base64Encoded: b64) {
            request.httpBody = data
        }
        let label = "\(method) \(url.host ?? "?")\(url.path)"
        qlog(.debug, "ext-fetch", "→ \(method) \(Self.redactedQueryURL(url))")
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                headers["\(k)"] = "\(v)"
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            qlog(status >= 400 ? .warn : .debug, "ext-fetch", "\(label) → \(status)（\(data.count) bytes, \(ms)ms）")
            return [
                "url": http?.url?.absoluteString ?? urlString,
                "status": status,
                // localizedString は端末の言語（日本語）になり、JS の Response が受け付けないので英語の定型句を使う
                "statusText": Self.reasonPhrase(status),
                "headers": headers,
                "body": data.base64EncodedString(),
                "redirected": (http?.url?.absoluteString ?? urlString) != urlString,
            ]
        } catch {
            qlog(.warn, "ext-fetch", "\(label) 失敗: \(error.localizedDescription)")
            return ["error": error.localizedDescription]
        }
    }
}

extension ExtensionHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        qlog(.error, "ext-host", "ランタイムの読み込みに失敗: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        qlog(.error, "ext-host", "WebContent プロセスが終了しました。ランタイムを読み込み直します（拡張は再読み込みが必要）")
        isReady = false
        loadPage()
        Task { await ExtensionManager.shared.reloadAll(reason: "WebContent プロセス終了") }
    }
}

/// JS の fetch をネイティブへ中継する（返り値付きメッセージ）
@MainActor
final class ExtensionFetchHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: ExtensionHost?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let host else {
            return (["error": "不正なリクエスト"], nil)
        }
        let result = await host.performFetch(body)
        return (result, nil)
    }
}

/// JS の console.* をログへ流す
@MainActor
final class ExtensionLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let levelName = body["level"] as? String ?? "debug"
        let text = body["message"] as? String ?? ""
        let level: LogLevel
        switch levelName {
        case "error": level = .error
        case "warn": level = .warn
        case "info": level = .info
        default: level = .debug
        }
        qlog(level, "ext", text)
    }
}

/// 隠し WKWebView をビュー階層に置いておく（階層外だと JS のタイマーが止まることがあるため）
struct ExtensionHostAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isUserInteractionEnabled = false
        container.alpha = 0.01
        let web = ExtensionHost.shared.webView!
        web.removeFromSuperview()
        web.frame = container.bounds
        container.addSubview(web)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
