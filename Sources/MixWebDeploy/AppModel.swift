import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }
    @Published private(set) var state: RunState = .idle
    @Published private(set) var logText = ""
    @Published private(set) var branches: [String] = []

    private let defaultsKey = "MixWebDeploy.settings.v1"
    private var process: Process?
    private var pipe: Pipe?
    private var temporaryScriptURL: URL?
    private var rawOutput = ""
    private var runningAction: RemoteAction?

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
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

        logText = ""
        rawOutput = ""
        runningAction = action
        state = .running("正在\(action.displayName)…")
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
                settings.host,
                settings.port,
                settings.username,
                settings.privateKeyPath,
                settings.projectPath,
                settings.firstMenuChoice,
                settings.secondMenuChoice,
                settings.branch
            ]
            task.standardOutput = outputPipe
            task.standardError = outputPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in
                    self?.consume(chunk)
                }
            }

            task.terminationHandler = { [weak self] finishedTask in
                let status = finishedTask.terminationStatus
                Task { @MainActor [weak self] in
                    self?.finish(exitStatus: status)
                }
            }

            process = task
            pipe = outputPipe
            try task.run()
        } catch {
            finishWithLaunchError(error)
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        appendLocalLog("正在停止当前操作…")
        process.terminate()
    }

    func clearLog() {
        guard !isRunning else { return }
        logText = ""
        rawOutput = ""
        state = .idle
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func writeTemporaryExpectScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mix-web-deploy-\(UUID().uuidString).exp")
        try ExpectProgram.source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func consume(_ chunk: String) {
        rawOutput += chunk
        let cleaned = OutputParser.cleanForDisplay(chunk)
        guard !cleaned.isEmpty else { return }
        logText += cleaned
    }

    private func appendLocalLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        logText += line
    }

    private func finish(exitStatus: Int32) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        cleanupTemporaryScript()

        let action = runningAction
        process = nil
        pipe = nil
        runningAction = nil

        if exitStatus == 0 {
            if action == .branches {
                let parsedBranches = OutputParser.branches(from: rawOutput)
                branches = parsedBranches
                if settings.branch.isEmpty, let first = parsedBranches.first {
                    settings.branch = first
                }
                appendLocalLog("读取到 \(parsedBranches.count) 个远程分支。")
            }

            let message = action == .deploy ? "分支切换和拉取完成" : "\(action?.displayName ?? "操作")完成"
            state = .success(message)
            appendLocalLog(message)
        } else {
            let message = protocolErrorMessage() ?? "操作失败，退出码：\(exitStatus)"
            state = .failure(message)
            appendLocalLog(message)
            NSSound.beep()
        }
    }

    private func finishWithLaunchError(_ error: Error) {
        cleanupTemporaryScript()
        process = nil
        pipe = nil
        runningAction = nil
        let message = "无法启动 expect：\(error.localizedDescription)"
        state = .failure(message)
        appendLocalLog(message)
        NSSound.beep()
    }

    private func protocolErrorMessage() -> String? {
        guard let range = rawOutput.range(of: "__MWD_ERROR__:", options: .backwards) else {
            return nil
        }

        let remainder = rawOutput[range.upperBound...]
        return remainder
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first
            .map(String.init)
    }

    private func cleanupTemporaryScript() {
        guard let url = temporaryScriptURL else { return }
        try? FileManager.default.removeItem(at: url)
        temporaryScriptURL = nil
    }
}
