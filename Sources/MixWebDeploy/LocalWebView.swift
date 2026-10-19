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
final class MacWebBridge: MacWebChannel {
    let model: LocalBuildModel
    private let remoteBusy: () -> Bool
    private var lastSelection: UUID?
    private let confirmBuildClear: (String) -> Bool
    private var confirmingClear = false
    private static let actions: Set<String> = ["state", "buildFiles", "clearBuild", "saveSettings", "chooseProject", "chooseLibrary", "buildSave", "buildInstall", "download", "import", "install", "updateMetadata", "restore", "openArchive", "copyLog", "cancel"]

    init(model: LocalBuildModel, remoteBusy: @escaping () -> Bool = { false }, confirmBuildClear: ((String) -> Bool)? = nil) {
        self.model = model; self.remoteBusy = remoteBusy
        self.confirmBuildClear = confirmBuildClear ?? Self.confirmClear
        super.init(page: MacWebAssets.page, allowed: Self.actions)
        observe(model)
    }

    override func stopOperation() { if model.isRunning { model.stop() } }

    override func handle(_ action: String, args: [String: Any]) throws -> [String: Any] {
        guard Self.actions.contains(action) else { throw LocalBuildError.message("不支持的本地操作。") }
        if action == "state" { model.refresh(); return ["snapshot": snapshot()] }
        if action == "buildFiles" {
            let directory = try BuildDirectory.read(text(args, "projectPath"))
            let date = ISO8601DateFormatter()
            return ["buildDirectory": ["path": directory.path, "exists": directory.exists, "entryCount": directory.entryCount,
                "files": directory.files.map { ["name": $0.name, "size": $0.size, "modifiedAt": date.string(from: $0.modifiedAt)] as [String: Any] }]]
        }
        if action == "cancel" { model.stop(); return ["snapshot": snapshot()] }
        if action == "copyLog" { model.copyLog(); return ["message": "日志已复制"] }
        guard !model.isRunning, !remoteBusy(), !confirmingClear else { throw LocalBuildError.message("当前操作尚未结束，请稍后重试。") }
        if let settings = args["settings"] as? [String: Any] {
            model.settings = LocalBuildSettings(projectPath: try text(settings, "projectPath"), libraryPath: try text(settings, "libraryPath"))
        }
        switch action {
        case "clearBuild":
            let path = try BuildDirectory.project(model.settings.projectPath).appendingPathComponent("build").path
            confirmingClear = true
            let confirmed = confirmBuildClear(path)
            confirmingClear = false
            guard confirmed else { return ["snapshot": snapshot(), "message": "已取消清空，build 文件未改动"] }
            model.clearBuild()
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

    private func identifier(_ args: [String: Any]) throws -> UUID {
        guard let id = UUID(uuidString: try text(args, "id", limit: 36)) else { throw LocalBuildError.message("记录 ID 无效。") }
        return id
    }

    private static func confirmClear(_ path: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空 build 文件夹？"
        alert.informativeText = "将删除以下目录内的所有文件和子目录，保留 build 目录本身：\n\n\(path)\n\n删除不可撤销；已保存的 JS 历史和 AdsPower 安装文件不受影响。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空 build")
        return alert.runModal() == .alertSecondButtonReturn
    }

    override func snapshot() -> [String: Any] {
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

}
