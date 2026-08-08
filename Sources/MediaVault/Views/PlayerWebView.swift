import SwiftUI
import WebKit
import AppKit
import LocalAuthentication

// MARK: - Coordinator

@MainActor
final class PlayerCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let store: SourceStore
    weak var webView: WKWebView?

    init(store: SourceStore) {
        self.store = store
    }

    // Called once the page has loaded — inject the library
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await loadLibrary(into: webView) }
    }

    private func loadLibrary(into webView: WKWebView) async {
        let scan = VideoScanner.scan(store: store)
        let payload: [String: [MediaItem]] = ["public": scan.public, "private": scan.private]
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("loadLibrary(JSON.parse('\(escaped)'))", completionHandler: nil)
    }

    // JS → Swift bridge
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        Task { @MainActor in
            switch action {
            case "showInFinder":
                if let path = body["path"] as? String {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            case "setLiked":
                if let path = body["path"] as? String, let liked = body["liked"] as? Bool {
                    let url = URL(fileURLWithPath: path)
                    LikeStore.setLiked(url, liked)
                }
            case "authenticate":
                await performAuth()
            default:
                break
            }
        }
    }

    private func performAuth() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            webView?.evaluateJavaScript("enterPrivateMode()", completionHandler: nil)
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock private content")
            if ok {
                webView?.evaluateJavaScript("enterPrivateMode()", completionHandler: nil)
            } else {
                webView?.evaluateJavaScript("authFailed()", completionHandler: nil)
            }
        } catch {
            webView?.evaluateJavaScript("authFailed()", completionHandler: nil)
        }
    }
}

// MARK: - NSViewRepresentable

struct PlayerWebView: NSViewRepresentable {
    let store: SourceStore

    func makeCoordinator() -> PlayerCoordinator { PlayerCoordinator(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "native")

        // Allow file:// access so <video src> and <img src> resolve against the download root
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Load the bundled HTML
        if let htmlURL = Bundle.module.url(forResource: "player", withExtension: "html", subdirectory: "Resources") {
            let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
            let baseURL = store.downloadRootURL
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
