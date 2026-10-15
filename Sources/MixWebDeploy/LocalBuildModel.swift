import AppKit
import Foundation

@MainActor
final class LocalBuildModel: ObservableObject {
    @Published var settings: LocalBuildSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: defaultsKey) }
            if !isRunning, settings != oldValue {
                state = .idle
                currentStage = nil
                result = nil
                resultSummary = nil
            }
        }
    }
    @Published private(set) var state: RunState = .idle
    @Published private(set) var currentStage: RunStage?
    @Published private(set) var result: LocalBuildResult?
    @Published private(set) var resultSummary: String?
    @Published private(set) var logText = ""
    @Published private(set) var isStopping = false
    @Published var showResult = false
    private let defaults: UserDefaults
    private let defaultsKey = "MixWebDeploy.localBuild.v1"
    private var cancellation: LocalBuildCancellation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(LocalBuildSettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
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

    func start() {
        guard !isRunning else { return }
        let snapshot = settings
        let token = LocalBuildCancellation()
        cancellation = token
        state = .running("正在检查本地项目…")
        currentStage = .localCheck
        result = nil
        resultSummary = nil
        isStopping = false
        showResult = false
        logText = ""
        let start = Date()
        let stream = AsyncStream<LocalBuildEvent> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try LocalBuildService(cancellation: token).run(settings: snapshot) {
                        continuation.yield($0)
                    }
                    continuation.yield(.completed(result))
                } catch {
                    continuation.yield(.failed(error))
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
                case let .message(message): self.appendLog(message)
                case let .completed(result):
                    self.result = result
                    self.currentStage = .complete
                    self.resultSummary = "\(result.branch) · \(result.artifact.lastPathComponent) · 耗时 \(Int(Date().timeIntervalSince(start))) 秒"
                    self.state = .success("打包完成，已替换 main.min.js")
                    self.appendLog(self.state.message)
                    self.showResult = true
                case let .failed(error):
                    if case LocalBuildError.cancelled = error {
                        self.state = .cancelled
                    } else {
                        self.state = .failure(LogRedactor(settings: .defaults).redact(error.localizedDescription))
                        self.showResult = true
                        NSSound.beep()
                    }
                    self.appendLog(self.state.message)
                }
            }
            self?.cancellation = nil
            self?.isStopping = false
        }
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        state = .running("正在停止本地打包…")
        cancellation?.cancel()
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    private func appendLog(_ message: String) {
        let safe = LogRedactor(settings: .defaults).redact(message)
        guard !safe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        logText += safe + "\n"
        if logText.count > 100_000 { logText = "（较早日志已省略）\n" + String(logText.suffix(80_000)) }
    }
}
