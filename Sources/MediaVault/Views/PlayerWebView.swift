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
        // Collect store info on main actor first, then scan off-thread
        let entries: [(source: FollowedSource, dir: URL, isPrivate: Bool)] = store.sources.compactMap { source in
            guard let dir = store.downloadDir(for: source) else { return nil }
            let isPrivate = store.group(for: source)?.isPrivate ?? false
            return (source, dir, isPrivate)
        }
        let scan = await Task.detached(priority: .userInitiated) {
            VideoScanner.scan(sources: entries)
        }.value
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
        let rawBody = message.body  // capture before crossing actor boundary
        Task { @MainActor in
            guard let body = rawBody as? [String: Any],
                  let action = body["action"] as? String else { return }
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
            case "changeThumbnail":
                if let path = body["path"] as? String {
                    await regenerateThumbnail(for: path)
                }
            case "authenticate":
                await performAuth()
            default:
                break
            }
        }
    }

    private func regenerateThumbnail(for path: String) async {
        let videoURL   = URL(fileURLWithPath: path)
        let ffmpegPath = ToolChecker.shared.ffmpegPath
        let newPath    = await Task.detached(priority: .userInitiated) {
            await ThumbnailGenerator.regenerate(for: videoURL, ffmpegPath: ffmpegPath)
        }.value
        let escaped = (newPath ?? "").replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "'", with: "\\'")
        let pathEscaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("thumbnailReady('\(pathEscaped)', '\(escaped)')", completionHandler: nil)
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

        // Load the bundled HTML with file access so media src paths resolve
        let htmlURL = Bundle.main.url(forResource: "player", withExtension: "html")
            ?? Bundle.main.resourceURL?.appendingPathComponent("player.html")
        if let htmlURL, FileManager.default.fileExists(atPath: htmlURL.path) {
            let accessRoot = store.downloadRootURL ?? htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: accessRoot)
        } else {
            // Fallback: log and show error page so we can diagnose
            let bundles = [Bundle.main.bundlePath, Bundle.main.resourcePath ?? "nil"]
            let msg = "player.html not found. Bundle paths: \(bundles)"
            print("[PlayerWebView] \(msg)")
            webView.loadHTMLString("<pre style='color:red'>\(msg)</pre>", baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
