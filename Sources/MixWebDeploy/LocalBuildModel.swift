import AppKit
import Foundation

private enum JSWorkbenchEvent {
    case stage(RunStage)
    case log(String)
    case saved(JSArtifact)
    case snapshot(JSArchiveIndex)
    case finished(String, LocalBuildResult?, JSInstallation?)
    case failed(Error)
}

@MainActor
final class LocalBuildModel: ObservableObject {
    @Published var settings: LocalBuildSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: defaultsKey) }
            if !isRunning, settings != oldValue {
                state = .idle
                currentStage = nil
                result = nil
                installation = nil
                resultSummary = nil
                selectedBackupID = availableBackups.first?.id
            }
        }
    }
    @Published private(set) var state: RunState = .idle
    @Published private(set) var currentStage: RunStage?
    @Published private(set) var stages: [RunStage] = []
    @Published private(set) var result: LocalBuildResult?
    @Published private(set) var installation: JSInstallation?
    @Published private(set) var resultSummary: String?
    @Published private(set) var logText = ""
    @Published private(set) var isStopping = false
    @Published private(set) var records: [JSArtifact] = []
    @Published private(set) var backups: [JSBackup] = []
    @Published var selectedID: UUID?
    @Published var selectedBackupID: UUID?
    @Published var searchText = ""
    @Published var note = ""
    @Published var downloadURLText = ""
    @Published var expectedMD5 = ""
    @Published var showResult = false
    @Published private(set) var alertTitle = ""
    @Published private(set) var alertDetail = ""
    let store: JSArchiveStore
    private let downloader: JSDownloadClient
    private let defaults: UserDefaults
    private let defaultsKey = "MixWebDeploy.localBuild.v1"
    private var cancellation: LocalBuildCancellation?
    private var worker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, archiveRoot: URL = JSArchiveStore.defaultRoot, downloader: JSDownloadClient = JSDownloadClient()) {
        self.downloader = downloader
        self.defaults = defaults
        store = JSArchiveStore(root: archiveRoot)
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(LocalBuildSettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
        do { accept(try store.load()) }
        catch { state = .failure("无法读取本地 JS 库：\(error.localizedDescription)") }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
    var filteredRecords: [JSArtifact] { records.filter { $0.matches(searchText) } }
    var selectedRecord: JSArtifact? { records.first { $0.id == selectedID } }
    var availableBackups: [JSBackup] {
        let target = URL(fileURLWithPath: settings.libraryPath).appendingPathComponent("main.min.js").resolvingSymlinksInPath().path
        return backups.filter { URL(fileURLWithPath: $0.targetPath).resolvingSymlinksInPath().path == target }
    }

    func chooseDirectory(isProject: Bool) {
        let panel = NSOpenPanel()
        panel.title = isProject ? "选择本地 mix_client 项目" : "选择 AdsPower 的 lib 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: isProject ? settings.projectPath : settings.libraryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isProject { settings.projectPath = url.path } else { settings.libraryPath = url.path }
    }

    func start(installAfterBuild: Bool = true) {
        let settings = settings
        let store = store
        let note = note
        let stages: [RunStage] = [.localCheck, .build, .artifact, .archive]
            + (installAfterBuild ? [.backup, .replace] : []) + [.complete]
        perform(stages: stages) { token, emit in
            if installAfterBuild { _ = try JSFile.destination(in: settings.libraryPath) }
            let built = try LocalBuildService(cancellation: token).run(settings: settings, installAfterBuild: false) {
                switch $0 {
                case let .stage(stage): emit(.stage(stage))
                case let .message(message): emit(.log(message))
                default: break
                }
            }
            try token.check()
            emit(.stage(.archive))
            let record = try store.archive(built.artifact, sourceKind: .build, note: note, branch: built.branch)
            emit(.saved(record))
            var installation: JSInstallation?
            if installAfterBuild {
                installation = try store.install(id: record.id, libraryPath: settings.libraryPath, cancellation: token) { emit(.stage($0)) }
            }
            let result = LocalBuildResult(branch: built.branch, artifact: store.file(for: record), destination: built.destination,
                                          backup: installation?.backup, checksum: record.sha256, didInstall: installAfterBuild)
            return (installAfterBuild ? "打包完成，已保存并安装 \(record.version)" : "打包完成，已保存 \(record.version)，未替换目标",
                    result, installation)
        }
    }

    func download() {
        let downloader = downloader
        let text = downloadURLText
        let md5 = expectedMD5
        let note = note
        let store = store
        perform(stages: [.localCheck, .download, .artifact, .archive, .complete]) { token, emit in
            let spec = try JSDownloadSpec(text, expectedMD5: md5)
            emit(.stage(.download))
            emit(.log("开始下载 \(spec.filename)，仅使用 GET，不读取浏览器登录信息。"))
            let url = try await downloader.download(spec) { emit(.log($0)) }
            defer { try? FileManager.default.removeItem(at: url) }
            try token.check()
            emit(.stage(.artifact))
            let info = try JSFile.inspect(url)
            if let expected = spec.expectedMD5, info.md5 != expected {
                throw LocalBuildError.message("MD5 不一致，下载文件已丢弃，未归档或安装。")
            }
            emit(.log(spec.expectedMD5 == nil ? "链接未提供 MD5，已校验 JS 语法并计算本地 SHA-256。" : "下载内容的 MD5 校验通过。"))
            emit(.stage(.archive))
            let record = try store.archive(url, filename: spec.filename, sourceKind: .download, note: note, expectedMD5: spec.expectedMD5)
            emit(.saved(record))
            return ("下载完成，已保存 \(record.version)，可从历史记录选择安装", nil, nil)
        }
    }

    func clearBuild() {
        let path = settings.projectPath
        let protectedPaths = [settings.libraryPath, store.root.path]
        perform(stages: [.localCheck, .complete], showAlert: false) { token, emit in
            do {
                let count = try BuildDirectory.clear(path, protecting: protectedPaths, cancellation: token)
                return ("build 已清空，共删除 \(count) 项；本地 JS 历史和安装文件保留。", nil, nil)
            } catch {
                emit(.log("清空未完成；已经删除的 build 内容不会自动恢复，请核对实时列表。"))
                throw error
            }
        }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "选择完整的主 JS 文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    func importFile(_ url: URL) {
        let store = store
        let note = note
        perform(stages: [.artifact, .archive, .complete]) { token, emit in
            try token.check()
            _ = try JSFile.inspect(url)
            emit(.stage(.archive))
            let record = try store.archive(url, sourceKind: .file, note: note)
            emit(.saved(record))
            return ("已导入 \(record.version)，未替换目标", nil, nil)
        }
    }

    func installSelected() {
        guard let record = selectedRecord, filteredRecords.contains(where: { $0.id == record.id }) else { return }
        let store = store
        let path = settings.libraryPath
        perform(stages: [.artifact, .backup, .replace, .complete]) { token, emit in
            let installed = try store.install(id: record.id, libraryPath: path, cancellation: token) { emit(.stage($0)) }
            return ("已安装 \(record.version)，重新启动 AdsPower 后生效", nil, installed)
        }
    }

    func restoreSelected() {
        guard let id = selectedBackupID else { return }
        let store = store
        let path = settings.libraryPath
        perform(stages: [.artifact, .backup, .replace, .complete]) { token, emit in
            let installed = try store.restore(id: id, libraryPath: path, cancellation: token) { emit(.stage($0)) }
            return ("备份恢复成功，重新启动 AdsPower 后生效", nil, installed)
        }
    }

    func saveDetails(id: UUID, version: String, note: String) {
        let store = store
        perform(stages: [.archive, .complete], showAlert: false) { _, _ in
            try store.update(id: id, version: version, note: note)
            return ("版本和备注已保存在本机", nil, nil)
        }
    }

    func refresh() {
        guard !isRunning else { return }
        do { accept(try store.load()) } catch { state = .failure("读取 JS 库失败：\(error.localizedDescription)") }
    }

    func revealSelected() {
        guard let record = selectedRecord else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.file(for: record)])
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        state = .running("正在停止本地操作…")
        cancellation?.cancel()
        worker?.cancel()
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    private func perform(stages: [RunStage], showAlert: Bool = true,
                         operation: @escaping @Sendable (LocalBuildCancellation, @escaping @Sendable (JSWorkbenchEvent) -> Void) async throws
                         -> (String, LocalBuildResult?, JSInstallation?)) {
        guard !isRunning else { return }
        let token = LocalBuildCancellation()
        let store = store
        cancellation = token
        self.stages = stages
        state = .running("正在\(stages.first?.title ?? "处理")…")
        currentStage = stages.first
        result = nil
        installation = nil
        resultSummary = nil
        isStopping = false
        showResult = false
        logText = ""
        let started = Date()
        let stream = AsyncStream<JSWorkbenchEvent> { continuation in
            worker = Task.detached(priority: .userInitiated) {
                let emit: @Sendable (JSWorkbenchEvent) -> Void = { continuation.yield($0) }
                do {
                    let output = try await operation(token, emit)
                    emit(.snapshot(try store.load()))
                    emit(.finished(output.0, output.1, output.2))
                } catch {
                    if let index = try? store.load() { emit(.snapshot(index)) }
                    emit(.failed(error))
                }
                continuation.finish()
            }
        }
        Task { [weak self] in
            for await event in stream {
                guard let self else { token.cancel(); continue }
                switch event {
                case let .stage(stage):
                    self.currentStage = stage
                    if !self.isStopping { self.state = .running("正在\(stage.title)…") }
                case let .log(message): self.appendLog(message)
                case let .saved(record):
                    self.selectedID = record.id
                    self.searchText = ""
                    self.appendLog("已保存：\(record.version) · \(record.md5)")
                case let .snapshot(index): self.accept(index)
                case let .finished(message, result, installation):
                    self.result = result
                    self.installation = installation
                    self.currentStage = .complete
                    self.resultSummary = "耗时 \(Int(Date().timeIntervalSince(started))) 秒"
                    self.state = .success(message)
                    self.appendLog(message)
                    self.alertTitle = installation == nil ? "已保存到本地" : "本地安装完成"
                    self.alertDetail = message
                    if let installation {
                        self.alertDetail += "\n\n目标：\(installation.destination.path)\n备份：\(installation.backup?.path ?? "原文件不存在，无需备份")"
                    }
                    self.showResult = showAlert
                case let .failed(error):
                    if error is CancellationError || (error as? LocalBuildError).map({ if case .cancelled = $0 { return true }; return false }) == true {
                        self.state = .cancelled
                    } else {
                        self.state = .failure(LogRedactor(settings: .defaults).redact(error.localizedDescription))
                        self.alertTitle = "操作未完成"
                        self.alertDetail = self.state.message + "\n已归档的 JS 和原文件备份会保留，可在历史记录中重试。"
                        self.showResult = true
                        NSSound.beep()
                    }
                    self.appendLog(self.state.message)
                }
            }
            self?.worker = nil
            self?.cancellation = nil
            self?.isStopping = false
        }
    }

    private func accept(_ index: JSArchiveIndex) {
        records = index.artifacts
        backups = index.backups
        if !records.contains(where: { $0.id == selectedID }) { selectedID = records.first?.id }
        if !availableBackups.contains(where: { $0.id == selectedBackupID }) { selectedBackupID = availableBackups.first?.id }
    }

    private func appendLog(_ message: String) {
        let safe = LogRedactor(settings: .defaults).redact(message)
        guard !safe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        logText += safe + "\n"
        if logText.count > 100_000 { logText = "（较早日志已省略）\n" + String(logText.suffix(80_000)) }
    }
}
