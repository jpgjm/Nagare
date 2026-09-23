import Foundation
import UIKit
import MachO

/// 実行時の環境情報。ログの書き出し時に先頭へ付ける。
/// Bundle ID は SideStore がチーム ID を付けて書き換えるため、必ず実行時の値を使う。
enum RuntimeInfo {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "(不明)" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    @MainActor
    static var systemVersion: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }

    static func summaryLines() -> [String] {
        var lines = [
            "Nagare \(version) (\(build))",
            "BundleID: \(bundleID)",
            "Device: \(deviceModel)",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        lines.append(contentsOf: loadedSSLImages().map { "Loaded: \($0)" })
        return lines
    }

    /// 読み込まれているイメージのうち OpenSSL 系のもの
    static func loadedSSLImages() -> [String] {
        var result: [String] = []
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName)
            let lower = name.lowercased()
            if lower.contains("ssl") || lower.contains("crypto") {
                result.append((name as NSString).lastPathComponent)
            }
        }
        return result
    }

    /// シンボルがどのイメージから見えているか（診断用）
    static func symbolOwner(_ symbol: String) -> String {
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
              let sym = dlsym(handle, symbol) else { return "見つからない" }
        var info = Dl_info()
        guard dladdr(sym, &info) != 0, let fname = info.dli_fname else { return "不明" }
        return (String(cString: fname) as NSString).lastPathComponent
    }

    /// OpenSSL のバージョン文字列（見えている実装のもの）
    static func openSSLVersion() -> String {
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(handle, "OpenSSL_version") else { return "見つからない" }
        typealias Fn = @convention(c) (Int32) -> UnsafePointer<CChar>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let c = fn(0) else { return "不明" }
        return String(cString: c)
    }

    static func logStartup() {
        qlog(.info, "app", "起動: " + summaryLines().prefix(4).joined(separator: " / "))
        qlog(.info, "diag", "OpenSSL: \(openSSLVersion()) / SSL_CTX_new → \(symbolOwner("SSL_CTX_new"))")
        let images = loadedSSLImages()
        qlog(.debug, "diag", "SSL 系イメージ: " + (images.isEmpty ? "なし（静的リンクのみ）" : images.joined(separator: ", ")))
    }
}
