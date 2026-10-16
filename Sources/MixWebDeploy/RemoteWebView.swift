import SwiftUI
import WebKit

@MainActor
struct RemoteWebView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var local: LocalBuildModel
    let requestDeploy: () -> Void

    func makeCoordinator() -> RemoteWebBridge {
        RemoteWebBridge(model: model, localBusy: { local.isRunning }, requestDeploy: requestDeploy)
    }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.observe(local)
        return context.coordinator.makeWebView(assets: Bundle.main.resourceURL!.appendingPathComponent("WebUI"))
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: RemoteWebBridge) { coordinator.detach() }
}

@MainActor
final class RemoteWebBridge: MacWebChannel {
    let model: AppModel
    private let localBusy: () -> Bool
    private let requestDeploy: () -> Void
    private static let actions: Set<String> = ["state", "saveSettings", "choosePrivateKey", "test", "branches", "syncBranches", "selectBranch", "deploy", "cancel", "copyLog", "clearLog"]

    init(model: AppModel, localBusy: @escaping () -> Bool = { false }, requestDeploy: @escaping () -> Void) {
        self.model = model; self.localBusy = localBusy; self.requestDeploy = requestDeploy
        super.init(page: MacWebAssets.serverPage, allowed: Self.actions)
        observe(model)
    }

    override func stopOperation() { if model.isRunning { model.stop() } }

    override func handle(_ action: String, args: [String: Any]) throws -> [String: Any] {
        guard Self.actions.contains(action) else { throw LocalBuildError.message("不支持的服务器操作。") }
        if action == "state" { return ["snapshot": snapshot()] }
        if action == "cancel" { model.stop(); return ["snapshot": snapshot()] }
        if action == "copyLog" { model.copyLog(); return ["message": "脱敏日志已复制"] }
        guard !model.isRunning, !localBusy() else { throw LocalBuildError.message("当前操作尚未结束，请稍后重试。") }
        if let values = args["settings"] as? [String: Any] {
            model.settings = AppSettings(host: try text(values, "host"), port: try text(values, "port", limit: 5),
                username: try text(values, "username"), privateKeyPath: try text(values, "privateKeyPath"),
                projectPath: try text(values, "projectPath"), firstMenuChoice: try text(values, "firstMenuChoice", limit: 100),
                secondMenuChoice: try text(values, "secondMenuChoice", limit: 100), branch: try text(values, "branch"))
        }
        switch action {
        case "choosePrivateKey": model.choosePrivateKey()
        case "test", "branches", "syncBranches":
            guard let operation = RemoteAction(rawValue: action) else { break }
            model.run(operation)
        case "selectBranch":
            let branch = try text(args, "branch")
            guard model.branches.contains(branch) else { throw LocalBuildError.message("请选择当前列表中的有效分支。") }
            model.settings.branch = branch
        case "deploy":
            guard let error = ConfigValidator.validate(settings: model.settings, action: .deploy) else {
                requestDeploy()
                return ["snapshot": snapshot()]
            }
            throw LocalBuildError.message(error)
        case "clearLog": model.clearLog()
        default: break
        }
        return ["snapshot": snapshot()]
    }

    override func snapshot() -> [String: Any] {
        let settings = model.settings
        let status: String
        switch model.state {
        case .idle: status = "idle"
        case .running: status = "running"
        case .success: status = "success"
        case .failure: status = "failure"
        case .cancelled: status = "cancelled"
        }
        let steps = model.displayedAction?.stages ?? []
        let current = steps.firstIndex(of: model.currentStage ?? .connect) ?? 0
        let stages: [[String: Any]] = steps.enumerated().map { index, stage in
            let state = status == "success" || index < current ? "done" : index == current ? status : "pending"
            return ["key": stage.rawValue, "title": stage.title, "state": state]
        }
        let operation: Any = status == "idle" ? NSNull() : ["state": status, "stage": model.currentStage?.title ?? "连接检查",
            "message": model.state.message, "summary": model.resultSummary ?? "", "stages": stages] as [String: Any]
        return ["settings": ["host": settings.host, "port": settings.port, "username": settings.username,
                "privateKeyPath": settings.privateKeyPath, "projectPath": settings.projectPath,
                "firstMenuChoice": settings.firstMenuChoice, "secondMenuChoice": settings.secondMenuChoice, "branch": settings.branch],
                "branches": model.branches, "branchListMessage": model.branchListMessage,
                "connectionNeedsAttention": model.connectionNeedsAttention, "busy": model.isRunning || localBusy(),
                "localBusy": localBusy(), "stopping": model.isStopping, "logs": model.logText, "operation": operation]
    }
}
