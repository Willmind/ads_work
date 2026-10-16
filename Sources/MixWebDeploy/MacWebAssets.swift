import Foundation
import WebKit

final class MacWebAssets: NSObject, WKURLSchemeHandler {
    static let page = URL(string: "adswork://app/index.html")!
    let root: URL
    private let types = ["index.html": "text/html", "styles.css": "text/css", "app.js": "text/javascript",
                         "bridge.js": "text/javascript", "preview.js": "text/javascript", "motion.js": "text/javascript", "logo.svg": "image/svg+xml"]

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "adswork", url.host == "app",
              url.query == nil, urlSchemeTask.request.httpMethod == "GET",
              let mime = types[String(url.path.dropFirst())] else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        do {
            let data = try Data(contentsOf: root.appendingPathComponent(String(url.path.dropFirst())))
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime + "; charset=utf-8", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff"
            ]) else { throw URLError(.badServerResponse) }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { /* Resources are served synchronously. */ }
}
