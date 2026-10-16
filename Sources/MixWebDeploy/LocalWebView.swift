import Combine
import SwiftUI
import WebKit

@MainActor
struct LocalWebView: NSViewRepresentable {
    @ObservedObject var model: LocalBuildModel
    @ObservedObject var remote: AppModel

    func makeCoordinator() -> MacWebBridge { MacWebBridge(model: model, remoteBusy: { remote.isRunning }) }

    func makeNSView(context: Context) -> WKWebView {
        let root = Bundle.main.resourceURL!.appendingPathComponent("WebUI", isDirectory: true)
        let view = context.coordinator.makeWebView(assets: root)
        context.coordinator.observe(remote)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: MacWebBridge) {
        coordinator.detach()
    }
}

@MainActor
final class MacWebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let model: LocalBuildModel
    private let remoteBusy: () -> Bool
    private weak var webView: WKWebView?
    private var subscriptions = Set<AnyCancellable>()
    private var lastSelection: UUID?
    private var hasRetriedContentProcess = false
    private let allowed: Set<String> = ["state", "saveSettings", "chooseProject", "chooseLibrary", "buildSave", "buildInstall", "download", "import", "install", "updateMetadata", "restore", "openArchive", "copyLog", "cancel"]

    init(model: LocalBuildModel, remoteBusy: @escaping () -> Bool = { false }) {
        self.model = model; self.remoteBusy = remoteBusy
        super.init()
        observe(model)
    }

    func makeWebView(assets: URL) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(MacWebAssets(root: assets), forURLScheme: "adswork")
        configuration.userContentController.add(self, name: "adswork")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        webView = view
        view.load(URLRequest(url: MacWebAssets.page))
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
        if model.isRunning { model.stop() }
        subscriptions.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adswork")
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url == MacWebAssets.page,
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
        guard allowed.contains(action) else { throw LocalBuildError.message("不支持的本地操作。") }
        if action == "state" { model.refresh(); return ["snapshot": snapshot()] }
        if action == "cancel" { model.stop(); return ["snapshot": snapshot()] }
        if action == "copyLog" { model.copyLog(); return ["message": "日志已复制"] }
        guard !model.isRunning, !remoteBusy() else { throw LocalBuildError.message("当前操作尚未结束，请稍后重试。") }
        if let settings = args["settings"] as? [String: Any] {
            model.settings = LocalBuildSettings(projectPath: try text(settings, "projectPath"), libraryPath: try text(settings, "libraryPath"))
        }
        switch action {
        case "saveSettings": return ["snapshot": snapshot(), "message": "路径已保存到本机"]
        case "chooseProject", "chooseLibrary": model.chooseDirectory(isProject: action == "chooseProject")
        case "buildSave", "buildInstall": model.note = try text(args, "note"); model.start(installAfterBuild: action == "buildInstall")
        case "download":
            model.note = try text(args, "note"); model.downloadURLText = try text(args, "url", limit: 8000)
            model.expectedMD5 = try text(args, "md5", limit: 32); model.download()
        case "import": model.note = try text(args, "note"); model.chooseImport()
        case "install", "openArchive", "updateMetadata":
            let id = try identifier(args)
            guard model.records.contains(where: { $0.id == id }) else { throw LocalBuildError.message("请选择有效的 JS 记录。") }
            model.selectedID = id; model.searchText = ""
            if action == "install" { model.installSelected() }
            else if action == "openArchive" { model.revealSelected() }
            else { model.saveDetails(id: id, version: try text(args, "version", limit: 100), note: try text(args, "note")) }
        case "restore":
            let id = try identifier(args)
            guard model.availableBackups.contains(where: { $0.id == id }) else { throw LocalBuildError.message("请选择当前目标的有效备份。") }
            model.selectedBackupID = id; model.restoreSelected()
        default: break
        }
        return ["snapshot": snapshot()]
    }

    private func text(_ args: [String: Any], _ key: String, limit: Int = 4000) throws -> String {
        guard let value = args[key] else { return "" }
        guard let text = value as? String, text.count <= limit else { throw LocalBuildError.message("请求参数类型或长度无效。") }
        return text
    }

    private func identifier(_ args: [String: Any]) throws -> UUID {
        guard let id = UUID(uuidString: try text(args, "id", limit: 36)) else { throw LocalBuildError.message("记录 ID 无效。") }
        return id
    }

    func snapshot() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let records: [[String: Any]] = model.records.map { record in
            ["id": record.id.uuidString.lowercased(), "fileName": record.filename, "version": record.version,
             "note": record.note, "sourceLabel": record.source.title, "createdAt": formatter.string(from: record.createdAt),
             "branch": record.branch as Any? ?? NSNull(), "sha256": record.sha256, "md5": record.md5, "size": record.size]
        }
        let backups: [[String: Any]] = model.availableBackups.map { backup in
            ["id": backup.id.uuidString.lowercased(), "createdAt": formatter.string(from: backup.createdAt), "label": backup.label]
        }
        let busy = model.isRunning || remoteBusy()
        var operation: Any = NSNull()
        let state: String
        switch model.state {
        case .idle: state = "idle"
        case .running: state = "running"
        case .success: state = "success"
        case .failure: state = "failure"
        case .cancelled: state = "cancelled"
        }
        if state != "idle" {
            operation = ["state": state, "stage": model.currentStage?.title ?? "本地操作", "message": model.state.message]
        }
        let selection = model.selectedID.flatMap { id in model.records.contains(where: { $0.id == id }) ? id : nil }
        let preferred: Any = selection != lastSelection ? selection?.uuidString.lowercased() as Any? ?? NSNull() : NSNull()
        lastSelection = selection
        return ["settings": ["projectPath": model.settings.projectPath, "libraryPath": model.settings.libraryPath],
                "records": records, "backups": backups, "busy": busy, "stopping": model.isStopping || remoteBusy(),
                "logs": model.logText, "operation": operation, "selectedId": preferred]
    }

    private func publish() { send(["type": "event", "event": "state", "data": snapshot()]) }

    private func send(_ message: [String: Any]) {
        guard let view = webView, view.url == MacWebAssets.page, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.__adsWorkReceive && window.__adsWorkReceive(\(json))") { _, error in
            if let error { NSLog("本地界面消息发送失败：%@", error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == MacWebAssets.page ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        model.stop()
        guard !hasRetriedContentProcess else {
            let alert = NSAlert()
            alert.messageText = "本地界面暂时无法加载"
            alert.informativeText = "系统网页进程已退出，请关闭工具后重新打开。已有 JS 记录和备份仍保存在本机。"
            if let window = webView.window { alert.beginSheetModal(for: window) }
            return
        }
        hasRetriedContentProcess = true
        webView.reload()
    }
}
