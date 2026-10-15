import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            saveSettings()
            guard settings != oldValue else { return }
            if !settings.hasSameConnection(as: oldValue) {
                branches = []
                branchListMessage = "连接已修改，请重新刷新分支"
            }
            if !isRunning {
                state = .idle
                displayedAction = nil
                currentStage = nil
                resultSummary = nil
            }
        }
    }
    @Published private(set) var state: RunState = .idle
    @Published private(set) var logText = ""
    @Published private(set) var branches: [String] = []
    @Published private(set) var branchListMessage = "快速刷新读取服务器已有记录；新建分支请点“同步远程”"
    @Published private(set) var displayedAction: RemoteAction?
    @Published private(set) var currentStage: RunStage?
    @Published private(set) var resultSummary: String?
    @Published private(set) var isStopping = false

    private let defaultsKey = "MixWebDeploy.settings.v1"
    private var process: Process?
    private var pipe: Pipe?
    private var temporaryScriptURL: URL?
    private var runningAction: RemoteAction?
    private let defaults: UserDefaults
    private let expectSource: String
    private var parser = OutputParser(settings: .defaults)
    private var runSettings: AppSettings?
    private var runID: UUID?
    private var exitStatus: Int32?
    private var outputEnded = false
    private var receivedDone = false
    private var receivedBranches: [String]?
    private var protocolError: String?
    private var commitSHA: String?
    private var startedAt: Date?

    init(defaults: UserDefaults = .standard, expectSource: String = ExpectProgram.source) {
        self.defaults = defaults
        self.expectSource = expectSource
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
    }

    var connectionNeedsAttention: Bool {
        ConfigValidator.validate(settings: settings, action: .test) != nil
    }

    var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 Jumpserver PEM 私钥"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if !settings.privateKeyPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.privateKeyPath).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.privateKeyPath = url.path
    }

    func run(_ action: RemoteAction) {
        guard !isRunning else { return }

        if let validationError = ConfigValidator.validate(settings: settings, action: action) {
            state = .failure(validationError)
            appendLocalLog("校验失败：\(validationError)")
            NSSound.beep()
            return
        }

        let snapshot = settings
        let id = UUID()
        runID = id
        runSettings = snapshot
        parser = OutputParser(settings: snapshot)
        exitStatus = nil
        outputEnded = false
        receivedDone = false
        receivedBranches = nil
        protocolError = nil
        commitSHA = nil
        isStopping = false
        startedAt = Date()
        resultSummary = nil
        logText = ""
        runningAction = action
        displayedAction = action
        currentStage = .connect
        state = .running("正在连接服务器…")
        appendLocalLog("开始：\(action.displayName)")

        do {
            let scriptURL = try writeTemporaryExpectScript()
            temporaryScriptURL = scriptURL

            let task = Process()
            let outputPipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            task.arguments = [
                "-f",
                scriptURL.path,
                action.rawValue,
                snapshot.host,
                snapshot.port,
                snapshot.username,
                snapshot.privateKeyPath,
                snapshot.projectPath,
                snapshot.firstMenuChoice,
                snapshot.secondMenuChoice,
                snapshot.branch
            ]
            task.standardOutput = outputPipe
            task.standardError = outputPipe

            task.terminationHandler = { [weak self] finishedTask in
                let status = finishedTask.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
                    self.exitStatus = status
                    self.finishIfReady()
                }
            }

            process = task
            pipe = outputPipe
            try task.run()
            outputPipe.fileHandleForWriting.closeFile()

            // Read once, in order. Finish only after both EOF and process exit so
            // the last branch/error/completion marker cannot be lost to a race.
            let handle = outputPipe.fileHandleForReading
            let stream = AsyncStream<Data> { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                }
            }
            Task { @MainActor [weak self] in
                for await data in stream {
                    guard let self, self.runID == id else { continue }
                    self.consume(data)
                }
                guard let self, self.runID == id else { return }
                self.consume(Data(), finished: true)
                self.outputEnded = true
                self.finishIfReady()
            }
        } catch {
            finishWithLaunchError(error)
        }
    }

    func stop() {
        guard let process, process.isRunning, !isStopping else { return }
        isStopping = true
        state = .running("正在停止…")
        appendLocalLog("正在断开连接；已经完成的远程步骤不会撤销。")
        process.terminate()
    }

    func clearLog() {
        guard !isRunning else { return }
        logText = ""
        state = .idle
        displayedAction = nil
        currentStage = nil
        resultSummary = nil
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func writeTemporaryExpectScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mix-web-deploy-\(UUID().uuidString).exp")
        try expectSource.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func consume(_ data: Data, finished: Bool = false) {
        for event in parser.append(data, finished: finished) {
            switch event {
            case let .stage(stage):
                guard stage != .complete, displayedAction?.stages.contains(stage) == true else { continue }
                currentStage = stage
                if !isStopping { state = .running("正在\(stage.title)…") }
                appendLocalLog("\(stage.title)…")
            case let .message(message): appendLocalLog(message)
            case let .branches(values): receivedBranches = values
            case let .failure(message): protocolError = message
            case let .commit(sha): commitSHA = sha
            case .done: receivedDone = true
            }
        }
    }

    private func appendLocalLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let safeMessage = LogRedactor(settings: runSettings ?? settings).redact(message)
        let line = "[\(formatter.string(from: Date()))] \(safeMessage)\n"
        logText += line
        if logText.count > 100_000 {
            logText = "（较早日志已省略）\n" + String(logText.suffix(80_000))
        }
    }

    private func finishIfReady() {
        guard outputEnded, let exitStatus, let action = runningAction else { return }
        cleanupTemporaryScript()
        pipe?.fileHandleForReading.closeFile()
        process = nil
        pipe = nil
        defer {
            runningAction = nil
            runID = nil
            runSettings = nil
            isStopping = false
        }

        if isStopping {
            state = .cancelled
            appendLocalLog("操作已停止。请检查服务器当前分支和提交后再继续。")
            return
        }

        let needsBranches = action == .branches || action == .syncBranches
        if exitStatus == 0 && receivedDone && protocolError == nil && (!needsBranches || receivedBranches != nil) {
            if needsBranches, let values = receivedBranches {
                branches = values
                if settings.branch.isEmpty, let first = values.first {
                    settings.branch = first
                }
                let source = action == .branches ? "服务器已有记录" : "已同步远程"
                branchListMessage = "\(source) · \(values.count) 个分支 · \(Date().formatted(date: .omitted, time: .shortened))"
                appendLocalLog("\(source)，读取到 \(values.count) 个分支。")
            }
            let message = action == .deploy ? "分支切换和拉取完成" : "\(action.displayName)完成"
            currentStage = .complete
            let elapsed = Int(Date().timeIntervalSince(startedAt ?? Date()))
            let detail = action == .deploy ? "\(runSettings?.branch ?? "") · \(commitSHA ?? "提交号未返回") · " : ""
            resultSummary = LogRedactor(settings: runSettings ?? settings).redact("\(detail)\(Date().formatted(date: .omitted, time: .shortened)) · 耗时 \(elapsed) 秒")
            state = .success(message)
            appendLocalLog(message)
            if let resultSummary { appendLocalLog(resultSummary) }
        } else {
            let reason = protocolError ?? (exitStatus == 0 ? "未收到完整执行结果，请重新检查服务器状态" : "操作异常结束，退出码：\(exitStatus)")
            let message = "\(currentStage?.title ?? action.displayName)失败：\(reason)"
            state = .failure(message)
            appendLocalLog(message)
            NSSound.beep()
        }
    }

    private func finishWithLaunchError(_ error: Error) {
        cleanupTemporaryScript()
        pipe?.fileHandleForReading.closeFile()
        pipe?.fileHandleForWriting.closeFile()
        process = nil
        pipe = nil
        runningAction = nil
        runID = nil
        isStopping = false
        let message = LogRedactor(settings: runSettings ?? settings).redact("无法启动连接程序：\(error.localizedDescription)")
        state = .failure(message)
        appendLocalLog(message)
        runSettings = nil
        NSSound.beep()
    }

    private func cleanupTemporaryScript() {
        guard let url = temporaryScriptURL else { return }
        try? FileManager.default.removeItem(at: url)
        temporaryScriptURL = nil
    }
}
