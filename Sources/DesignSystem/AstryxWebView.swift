//
//  AstryxWebView.swift
//  PupilIOS
//
//  本物の Astryx (React) を WKWebView でオフライン描画する面。
//
//  - HTML/JS/CSS は Resources/astryx/ に同梱（design/build.mjs の生成物 + 手書き HTML）。
//    外部 CDN 参照はゼロ。フォントも CSS に data URI で埋め込み済み。
//  - JS -> Swift: window.webkit.messageHandlers.pupil.postMessage({ name, payload })
//       name: "ready"   payload: { surface, core }
//             "setting" payload: { key, value }
//             "openurl" payload: { url }
//  - Swift -> JS: window.pupilUpdate(jsonString)  … 設定値のマージ
//                 window.PupilAstryx.mount("settings" | "about") … 面の切り替え
//
//  project.yml の Resources はグループ追加でもフォルダ参照 (type: folder) でも動くよう、
//  html の解決は「astryx サブディレクトリ → バンドル直下 → resourceURL/astryx」の順で探す。
//  （html は同ディレクトリの astryx.js / astryx.css を相対参照するので、3 ファイルが
//    同じ場所に落ちていればどちらの構成でも解決する）
//

import Foundation
import SwiftUI
import UIKit
import WebKit

/// 描画する面。CONTRACT §1 の 2 面のみ。
enum AstryxSurface: String {
    case about = "about"
    case settings = "settings"
}

struct AstryxWebView: UIViewRepresentable {

    static let messageHandlerName = "pupil"

    private let surface: AstryxSurface
    private let payload: [String: String]
    private let onEvent: (String, [String: String]) -> Void

    init(surface: AstryxSurface,
         payload: [String: String] = [:],
         onEvent: @escaping (String, [String: String]) -> Void) {
        self.surface = surface
        self.payload = payload
        self.onEvent = onEvent
    }

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface, payload: payload, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: AstryxWebView.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(AstryxTheme.shared.background)
        webView.scrollView.backgroundColor = UIColor(AstryxTheme.shared.background)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.apply(surface: surface, payload: payload)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView.navigationDelegate = nil
        webView.stopLoading()
        coordinator.webView = nil
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

        var onEvent: (String, [String: String]) -> Void
        weak var webView: WKWebView?

        private var surface: AstryxSurface
        private var payload: [String: String]

        private var isLoaded = false
        private var appliedSurface: AstryxSurface?
        private var appliedSignature: String?

        init(surface: AstryxSurface,
             payload: [String: String],
             onEvent: @escaping (String, [String: String]) -> Void) {
            self.surface = surface
            self.payload = payload
            self.onEvent = onEvent
            super.init()
        }

        // MARK: loading

        func load() {
            guard let webView = webView else { return }
            guard let url = AstryxWebView.htmlURL() else {
                webView.loadHTMLString(AstryxWebView.missingResourceHTML, baseURL: nil)
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        // MARK: state push

        func apply(surface newSurface: AstryxSurface, payload newPayload: [String: String]) {
            surface = newSurface
            payload = newPayload

            guard isLoaded, let webView = webView else { return }

            if appliedSurface != newSurface {
                appliedSurface = newSurface
                let script = "window.PupilAstryx && window.PupilAstryx.mount(\(AstryxWebView.jsString(newSurface.rawValue)));"
                webView.evaluateJavaScript(script, completionHandler: nil)
            }

            let signature = AstryxWebView.jsonText(newPayload)
            if appliedSignature != signature {
                appliedSignature = signature
                let script = "window.pupilUpdate && window.pupilUpdate(\(AstryxWebView.jsString(signature)));"
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            appliedSurface = nil
            appliedSignature = nil
            apply(surface: surface, payload: payload)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[AstryxWebView] navigation failed: %@", error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[AstryxWebView] provisional navigation failed: %@", error.localizedDescription)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == AstryxWebView.messageHandlerName else { return }
            guard let body = message.body as? [String: Any] else { return }
            guard let name = body["name"] as? String, !name.isEmpty else { return }

            var eventPayload: [String: String] = [:]
            if let raw = body["payload"] as? [String: Any] {
                for (key, value) in raw {
                    eventPayload[key] = AstryxWebView.stringValue(value)
                }
            }
            onEvent(name, eventPayload)
        }
    }

    // MARK: - bundle resolution

    /// `Resources/astryx/pupil-astryx.html` を探す。
    static func htmlURL() -> URL? {
        let bundle = Bundle.main
        let manager = FileManager.default

        if let url = bundle.url(forResource: "pupil-astryx", withExtension: "html", subdirectory: "astryx"),
           manager.fileExists(atPath: url.path) {
            return url
        }
        if let url = bundle.url(forResource: "pupil-astryx", withExtension: "html"),
           manager.fileExists(atPath: url.path) {
            return url
        }
        if let root = bundle.resourceURL {
            let candidates = [
                root.appendingPathComponent("astryx/pupil-astryx.html"),
                root.appendingPathComponent("Resources/astryx/pupil-astryx.html"),
            ]
            for candidate in candidates where manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        NSLog("[AstryxWebView] pupil-astryx.html not found in bundle")
        return nil
    }

    // MARK: - JS glue

    /// `[String: String]` -> 決定的な順序の JSON テキスト。
    static func jsonText(_ payload: [String: String]) -> String {
        guard !payload.isEmpty else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 任意の文字列を JS の文字列リテラルにする（U+2028/2029 もエスケープ）。
    static func jsString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{2028}":
                out += "\\u2028"
            case "\u{2029}":
                out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func stringValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if value is NSNull { return "" }
        return String(describing: value)
    }

    // MARK: - fallback

    /// リソースが欠けているときの説明ページ（黒画面にしない）。
    static let missingResourceHTML = """
    <!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html,body{margin:0;background:#1B1B1B;color:#FFFFFF;font:14px -apple-system,"Hiragino Sans",sans-serif}
      .wrap{padding:24px;line-height:1.6}
      h1{font-size:17px;margin:0 0 8px}
      p{color:#9E9E9E;margin:0 0 8px}
      code{color:#F1F1F1}
    </style></head><body><div class="wrap">
    <h1>Astryx リソースが見つかりません</h1>
    <p><code>Resources/astryx/pupil-astryx.html</code> をアプリバンドルから解決できませんでした。</p>
    <p>design/ で <code>npm run build</code> を実行し、生成物が Xcode のリソースに含まれているか確認してください。</p>
    </div></body></html>
    """
}
