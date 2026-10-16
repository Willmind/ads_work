import Combine
import WebKit

@MainActor
class MacWebChannel: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let page: URL
    private let allowed: Set<String>
    private weak var webView: WKWebView?
    private var subscriptions = Set<AnyCancellable>()
    private var hasRetriedContentProcess = false

    init(page: URL, allowed: Set<String>) {
        self.page = page; self.allowed = allowed
        super.init()
    }

    func makeWebView(assets: URL) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(MacWebAssets(root: assets), forURLScheme: "adswork")
        configuration.userContentController.add(self, name: "adswork")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        webView = view
        view.load(URLRequest(url: page))
        return view
    }

    func observe<T: ObservableObject>(_ source: T) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        source.objectWillChange
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.publish() }
            }.store(in: &subscriptions)
    }

    func detach() {
        stopOperation()
        subscriptions.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adswork")
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
              let object = message.body as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 65536,
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let action = object["action"] as? String, allowed.contains(action),
              let args = object["args"] as? [String: Any] else { return }
        do {
            let result = try handle(action, args: args)
            send(["id": id, "ok": true, "data": result])
        } catch {
            send(["id": id, "ok": false, "error": error.localizedDescription])
        }
    }

    func handle(_ action: String, args: [String: Any]) throws -> [String: Any] {
        throw LocalBuildError.message("不支持的界面操作。")
    }

    func snapshot() -> [String: Any] { [:] }
    func stopOperation() { }

    func text(_ args: [String: Any], _ key: String, limit: Int = 4000) throws -> String {
        guard let value = args[key] else { return "" }
        guard let text = value as? String, text.count <= limit else { throw LocalBuildError.message("请求参数类型或长度无效。") }
        return text
    }

    private func publish() { send(["type": "event", "event": "state", "data": snapshot()]) }

    private func send(_ message: [String: Any]) {
        guard let view = webView, view.url == page, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.__adsWorkReceive && window.__adsWorkReceive(\(json))") { _, error in
            if let error { NSLog("应用界面消息发送失败：%@", error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == page ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopOperation()
        guard !hasRetriedContentProcess else {
            let alert = NSAlert()
            alert.messageText = "应用界面暂时无法加载"
            alert.informativeText = "系统网页进程已退出，请关闭工具后重新打开。已有配置和本地记录仍保留。"
            if let window = webView.window { alert.beginSheetModal(for: window) }
            return
        }
        hasRetriedContentProcess = true
        webView.reload()
    }
}
