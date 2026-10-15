import Darwin
import Foundation

@main
enum SelfCheck {
    @MainActor
    static func main() async throws {
        var failures: [String] = []

        check(ConfigValidator.isValidBranch("develop"), "应接受 develop", failures: &failures)
        check(
            ConfigValidator.isValidBranch("feature/ADS-123_login-page"),
            "应接受常见 feature 分支",
            failures: &failures
        )
        check(!ConfigValidator.isValidBranch("-force"), "应拒绝 - 开头的分支", failures: &failures)
        check(!ConfigValidator.isValidBranch("feature/../../main"), "应拒绝路径穿越", failures: &failures)
        check(!ConfigValidator.isValidBranch("main; reboot"), "应拒绝命令字符", failures: &failures)
        check(!ConfigValidator.isValidBranch("feature//login"), "应拒绝双斜杠", failures: &failures)

        var sample = AppSettings.defaults
        sample.host = "jump.example.invalid"
        sample.username = "tester@example.invalid"
        sample.privateKeyPath = "/Users/test person/Desktop/test-key.pem"
        sample.projectPath = "/path/to/project"
        let output = """
        ignored output
        __MWD_BRANCHES_BEGIN__\r
        main\r
        feature/login\r
        main\r
        invalid branch\r
        __MWD_BRANCHES_END__\r
        ignored output
        """
        var parser = OutputParser(settings: sample)
        check(
            parser.append(Data(output.utf8), finished: true).contains(.branches(["feature/login", "main"])),
            "应解析、过滤并去重远程分支",
            failures: &failures
        )

        let coloredOutput = "\u{001B}\u{005B}32m完成\u{001B}\u{005B}0m\r\n__MWD_DEPLOY_OK__\r\n"
        var ansiParser = OutputParser(settings: sample)
        check(
            ansiParser.append(Data(coloredOutput.utf8), finished: true) == [.message("完成")],
            "应移除 ANSI 转义和协议标记",
            failures: &failures
        )

        var fragmented = OutputParser(settings: sample)
        let privateLine = "连接 \(sample.host) \(sample.username) \(sample.privateKeyPath) \(sample.projectPath)"
        var emitted: [RemoteEvent] = []
        for byte in privateLine.utf8 { emitted += fragmented.append(Data([byte])) }
        check(emitted.isEmpty, "完整行收齐前不得显示敏感信息", failures: &failures)
        emitted += fragmented.append(Data("\n__MWD_STAGE__:fetch\n__MWD_ERROR__:失败\n__MWD_DONE__".utf8), finished: true)
        check(emitted == [.message("连接 [SSH 主机] [SSH 用户] [私钥路径] [项目目录]"), .stage(.fetch), .failure("失败"), .done], "逐字节 UTF-8、脱敏、进度及 EOF 解析", failures: &failures)

        try checkBranchCommand(failures: &failures)
        try await checkSimulatedRuns(failures: &failures)

        if failures.isEmpty {
            print("Self-check passed")
            return
        }

        for failure in failures {
            fputs("Self-check failed: \(failure)\n", stderr)
        }
        exit(1)
    }

    private static func checkBranchCommand(failures: inout [String]) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mwd-git-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        func execute(_ executable: String, _ arguments: [String], input: String = "") throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = temp
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            process.environment = environment
            let output = Pipe()
            let stdin = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        // Test the exact production shell command against a temporary real Git repo.
        // The shell function replaces sudo; no privilege escalation or remote access occurs.
        let declaration = "set branchesCommand {"
        guard let line = ExpectProgram.source.components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix(declaration) && $0.hasSuffix("}") }) else {
            failures.append("找不到待验证的生产分支命令")
            return
        }
        let command = String(line.dropFirst(declaration.count).dropLast())
        let sudoStub = #"""
        sudo() {
            test "$1" = -n && test "$2" = git || return 99
            shift 2
            for arg in "$@"; do
                case "$arg" in *refname:*) printf 'fatal: unknown refname format\n' >&2; return 128 ;; esac
            done
            /usr/bin/git "$@"
        }
        """#
        check(try execute("/usr/bin/git", ["init", "--bare", "--quiet"]).0 == 0, "建立隔离测试仓库", failures: &failures)
        let empty = try execute("/bin/sh", ["-c", sudoStub + "\n" + command])
        check(empty.1.contains("__MWD_BRANCHES_BEGIN__\n\n__MWD_BRANCHES_END__"), "真实命令的空列表保留成功标记", failures: &failures)
        let object = try execute("/usr/bin/git", ["hash-object", "-w", "--stdin"], input: "branch format fixture")
        let sha = object.1.trimmingCharacters(in: .whitespacesAndNewlines)
        check(object.0 == 0, "建立本地测试对象", failures: &failures)
        for name in ["main", "feature/login", "origin/nested"] {
            check(try execute("/usr/bin/git", ["update-ref", "refs/remotes/origin/\(name)", sha]).0 == 0, "建立测试引用 \(name)", failures: &failures)
        }
        let result = try execute("/bin/sh", ["-c", sudoStub + "\n" + command])
        check(result.1.contains("__MWD_BRANCHES_BEGIN__") && result.1.contains("refs/remotes/origin/origin/nested") && !result.1.contains("FAIL"), "真实 Git 命令保留完整分支路径，不依赖 refname 格式修饰符", failures: &failures)
        let regression = try execute("/bin/sh", ["-c", sudoStub + "\n" + command.replacingOccurrences(of: "%(refname)", with: "%(refname:strip=3)")])
        check(regression.1.contains("__MWD_BRANCHES_FAIL_BEGIN__:128") && regression.1.contains("unknown refname format"), "兼容性模拟器应捕获旧实现回归且保留退出码与诊断", failures: &failures)
        let failed = try execute("/bin/sh", ["-c", "sudo() { printf 'mock diagnostic\\n' >&2; return 77; }\n" + command])
        check(failed.1.contains("__MWD_BRANCHES_FAIL_BEGIN__:77\nmock diagnostic\n__MWD_BRANCHES_FAIL_END__") && !failed.1.contains("__MWD_BRANCHES_BEGIN__"), "真实 Shell 失败路径保留 stderr 和退出码，不伪装空列表", failures: &failures)
        print("本地 Git 验证：完整引用、空列表、格式兼容性与失败协议")
    }

    @MainActor
    private static func checkSimulatedRuns(failures: inout [String]) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mwd-self-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let dummyKey = temp.appendingPathComponent("dummy.pem")
        try Data("test fixture, not a private key".utf8).write(to: dummyKey)
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mock-server.exp")
        let defaults = MemoryDefaults()
        var settings = AppSettings.defaults
        settings.host = "jump.example.invalid"
        settings.username = "tester@example.invalid"
        settings.privateKeyPath = dummyKey.path
        settings.projectPath = "/path/to/project"
        settings.branch = "main"
        defaults.set(try JSONEncoder().encode(settings), forKey: "MixWebDeploy.settings.v1")

        func makeModel(_ scenario: String) -> AppModel {
            // Substitute only the transport in a private test copy. Real SSH is never launched.
            let source = ExpectProgram.source.replacingOccurrences(
                of: "spawn -noecho {*}$sshCommand",
                with: "spawn -noecho /usr/bin/expect {\(server.path)} \(scenario)"
            )
            return AppModel(defaults: defaults, expectSource: source)
        }

        let quick = makeModel("quick")
        quick.run(.branches)
        await wait(quick)
        check(quick.state == .success("刷新分支完成"), "快速刷新成功（模拟服务器拒绝任何 fetch）", failures: &failures)
        check(quick.branches == ["feature/login", "main", "origin/nested"], "完整保留嵌套分支名且排除 HEAD 和其他远端", failures: &failures)
        check(!quick.logText.contains("同步远程…"), "快速刷新不执行同步阶段", failures: &failures)
        check(!quick.logText.contains("mock-private-banner") && !quick.logText.contains("mock-user@target"), "SSH 横幅与 Shell 提示符不会进入日志", failures: &failures)
        quick.settings.branch = "feature/login"
        check(quick.state == .idle && !quick.branches.isEmpty, "切换目标分支清除旧成功提示并保留同一服务器列表", failures: &failures)
        quick.settings.host = "other.example.invalid"
        quick.settings.username = "another@example.invalid"
        check(quick.branches.isEmpty && quick.state == .idle, "修改主机或用户清除旧分支列表", failures: &failures)
        let reloaded = AppModel(defaults: defaults)
        check(reloaded.settings.host == "other.example.invalid" && reloaded.settings.username == "another@example.invalid", "修改的主机与用户可持久化恢复", failures: &failures)
        defaults.set(try JSONEncoder().encode(settings), forKey: "MixWebDeploy.settings.v1")

        for (action, scenario, success) in [
            (RemoteAction.test, "normal", true),
            (.syncBranches, "normal", true),
            (.branches, "empty", true),
            (.branches, "read-fail", false),
            (.branches, "sudo-fail", false),
            (.branches, "ownership-fail", false),
            (.branches, "permission-fail", false),
            (.branches, "unknown-fail", false),
            (.syncBranches, "fetch-fail", false),
            (.deploy, "normal", true),
            (.deploy, "dirty", false),
            (.deploy, "pull-fail", false)
        ] {
            let model = makeModel(scenario)
            model.run(action)
            await wait(model)
            if success {
                if case .success = model.state {} else {
                    failures.append("模拟 \(action.rawValue)/\(scenario) 应成功：\(model.state.message)")
                }
                check(model.currentStage == .complete, "成功后进度完整：\(scenario)", failures: &failures)
                if action == .deploy {
                    check(model.resultSummary?.contains("a1b2c3d") == true, "部署结果显示真实解析的提交号", failures: &failures)
                }
                if scenario == "empty" { check(model.branches.isEmpty, "正确处理空分支列表", failures: &failures) }
            } else {
                if case .failure = model.state {} else { failures.append("模拟 \(scenario) 应失败") }
                if scenario == "dirty" {
                    check(model.currentStage == .check && !model.logText.contains("切换分支…"), "脏工作区停止后不得执行切换", failures: &failures)
                }
                if scenario == "pull-fail" { check(model.currentStage == .pull, "失败定位拉取阶段", failures: &failures) }
                let expectedReasons = [
                    "read-fail": "项目目录不是 Git 仓库",
                    "sudo-fail": "远程 sudo 需要密码",
                    "ownership-fail": "属主不匹配",
                    "permission-fail": "被拒绝访问",
                    "unknown-fail": "退出码 77"
                ]
                if let reason = expectedReasons[scenario] {
                    check(model.state.message.contains(reason), "准确分类分支读取错误：\(scenario)", failures: &failures)
                    check(!model.state.message.contains("读取分支失败：读取分支失败"), "错误说明不重复：\(scenario)", failures: &failures)
                    check(!model.logText.contains("mock-secret-repo") && !model.logText.contains("private-user") && !model.logText.contains("private-host"), "Git 原始诊断中的内部信息不进入日志：\(scenario)", failures: &failures)
                }
            }
            print("模拟验证：\(action.rawValue) / \(scenario)")
        }

        let incomplete = AppModel(defaults: defaults, expectSource: "puts {__MWD_STAGE__:branches}\nexit 0")
        incomplete.run(.branches)
        await wait(incomplete)
        if case .failure = incomplete.state {} else { failures.append("缺少完成标记不能报告成功") }

        let stopping = AppModel(defaults: defaults, expectSource: "trap {exit 130} {SIGTERM SIGINT}\nputs {__MWD_STAGE__:connect}\nflush stdout\nafter 10000 {set finished 1}\nvwait finished")
        stopping.run(.test)
        try? await Task.sleep(nanoseconds: 200_000_000)
        stopping.stop()
        await wait(stopping)
        check(stopping.state == .cancelled, "停止操作明确显示已停止", failures: &failures)
    }

    @MainActor
    private static func wait(_ model: AppModel) async {
        let deadline = Date().addingTimeInterval(8)
        while model.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if model.isRunning {
            fputs("模拟超时：\(model.logText)\n", stderr)
            model.stop()
            for _ in 0..<50 where model.isRunning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private static func check(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition {
            failures.append(message)
        }
    }
}

// The test never reads or writes the user's actual application preferences.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
