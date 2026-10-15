import Darwin
import Foundation

@main
enum LocalBuildCheck {
    static let files = FileManager.default

    @MainActor
    static func main() async throws {
        let root = files.temporaryDirectory.appendingPathComponent("ads local build check \(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let cancellation = LocalBuildCancellation()
        let process = LocalBuildProcess(cancellation: cancellation)

        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LocalBuildError.message("Local build check failed: \(message)") }
        }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func fixture(_ name: String, script: String) throws -> LocalBuildSettings {
            let project = root.appendingPathComponent(name + " project")
            let library = root.appendingPathComponent(name + " lib")
            try files.createDirectory(at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
            try files.createDirectory(at: library, withIntermediateDirectories: true)
            try #"{"name":"ads-work-local-fixture","version":"1.0.0","scripts":{"buildLb":"node fixture.js"}}"#
                .write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try script.write(to: project.appendingPathComponent("fixture.js"), atomically: true, encoding: .utf8)
            try "old build".write(to: project.appendingPathComponent("build/v1_main.min.js"), atomically: true, encoding: .utf8)
            try "historic".write(to: project.appendingPathComponent("build/v0_main.min.js"), atomically: true, encoding: .utf8)
            try "original target".write(to: library.appendingPathComponent("main.min.js"), atomically: true, encoding: .utf8)
            _ = try process.run("/usr/bin/git", ["init", "-q", "-b", "fixture-branch"], in: project)
            _ = try process.run("/usr/bin/git", ["add", "package.json", "fixture.js"], in: project)
            _ = try process.run("/usr/bin/git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], in: project)
            return LocalBuildSettings(projectPath: project.path, libraryPath: library.path)
        }
        let write = "const fs = require('fs'); fs.writeFileSync('build/v1_main.min.js', 'fresh bundle');"
        let success = try fixture("same name", script: write)
        let service = LocalBuildService(cancellation: cancellation)
        let result = try service.run(settings: success) { _ in }
        try check(result.branch == "fixture-branch", "reports actual local branch")
        try check(try text(result.destination) == "fresh bundle", "same-name output replaces existing target")
        try check(try text(result.artifact) == "fresh bundle", "fresh build stays in build directory")
        try check(result.backup != nil && (try text(result.backup!)) == "original target", "backup preserves original bytes")
        try check(try text(URL(fileURLWithPath: success.projectPath).appendingPathComponent("build/v0_main.min.js")) == "historic", "historic output survives")
        try check(!files.fileExists(atPath: success.projectPath + "/.ads-work-build.lock"), "lock cleaned up")
        print("本地打包验证：带空格路径、同名产物、历史产物恢复、备份及实际分支")

        // Rebuild identical bytes; no mtime comparison is involved.
        let repeated = try service.run(settings: success) { _ in }
        try check(try text(repeated.destination) == "fresh bundle", "identical output may still be installed")
        try check(repeated.backup != result.backup, "backups never overwrite one another")

        for (name, script) in [
            ("failed", write + "process.exit(7);"),
            ("missing", "console.log('no bundle produced');"),
            ("ambiguous", write + "fs.writeFileSync('build/v2_main.min.js', 'second');"),
            ("empty", "require('fs').writeFileSync('build/v1_main.min.js', '');"),
            ("branch changed", write + "require('child_process').execFileSync('/usr/bin/git', ['checkout', '-qb', 'other']);")
        ] {
            let settings = try fixture(name, script: script)
            var failed = false
            do { _ = try service.run(settings: settings) { _ in } } catch { failed = true }
            let target = URL(fileURLWithPath: settings.libraryPath).appendingPathComponent("main.min.js")
            let oldBuild = URL(fileURLWithPath: settings.projectPath).appendingPathComponent("build/v1_main.min.js")
            try check(failed, "\(name) must fail")
            try check(try text(target) == "original target", "\(name) must preserve target")
            try check(try text(oldBuild) == "old build", "\(name) must restore old build")
            try check(!files.fileExists(atPath: settings.projectPath + "/.ads-work-build.lock"), "\(name) releases lock")
            print("本地打包验证：\(name) 保留原文件")
        }

        let stopped = try fixture("stopped", script: "require('fs').writeFileSync('child.pid', String(process.pid)); console.log('FIXTURE_STARTED'); setTimeout(() => {}, 15000);")
        let stopToken = LocalBuildCancellation()
        var wasCancelled = false
        do {
            _ = try LocalBuildService(cancellation: stopToken).run(settings: stopped) {
                if case let .message(message) = $0, message.contains("FIXTURE_STARTED") { stopToken.cancel() }
            }
        } catch LocalBuildError.cancelled { wasCancelled = true }
        let childPID = Int32(try text(URL(fileURLWithPath: stopped.projectPath).appendingPathComponent("child.pid")))!
        try check(wasCancelled && kill(childPID, 0) != 0, "cancel terminates npm's Node child")
        try check(try text(URL(fileURLWithPath: stopped.libraryPath).appendingPathComponent("main.min.js")) == "original target", "cancel preserves target")
        try check(try text(URL(fileURLWithPath: stopped.projectPath).appendingPathComponent("build/v1_main.min.js")) == "old build", "cancel restores artifact")
        print("本地打包验证：停止会终止子进程并恢复产物")

        var timedOut = false
        do { _ = try process.run("/bin/sh", ["-c", "sleep 15"], in: root, timeout: 0.2) }
        catch { timedOut = error.localizedDescription.contains("超时") }
        try check(timedOut, "process timeout is enforced")

        let locked = try fixture("locked", script: write)
        try Data().write(to: URL(fileURLWithPath: locked.projectPath).appendingPathComponent(".ads-work-build.lock"))
        var lockRejected = false
        do { _ = try service.run(settings: locked) { _ in } }
        catch { lockRejected = error.localizedDescription.contains("构建锁") }
        try check(lockRejected, "concurrent builds must be rejected")

        let symlink = try fixture("symlink", script: write)
        let target = URL(fileURLWithPath: symlink.libraryPath).appendingPathComponent("main.min.js")
        try files.removeItem(at: target)
        try files.createSymbolicLink(atPath: target.path, withDestinationPath: root.appendingPathComponent("missing.js").path)
        var symlinkRejected = false
        do { _ = try service.run(settings: symlink) { _ in } } catch { symlinkRejected = true }
        try check(symlinkRejected, "dangling target symlink must be rejected")
        let defaults = LocalMemoryDefaults()
        let model = LocalBuildModel(defaults: defaults)
        model.settings = success
        try check(LocalBuildModel(defaults: defaults).settings == success, "local paths persist independently of SSH settings")
        model.start()
        let deadline = Date().addingTimeInterval(15)
        while model.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if case .success = model.state {} else { throw LocalBuildError.message("model should report successful completion: \(model.state.message)") }
        try check(model.currentStage == .complete && model.showResult && model.result?.branch == "fixture-branch", "UI receives progress, result and alert")
        model.settings.projectPath = root.appendingPathComponent("missing").path
        model.start()
        let failureDeadline = Date().addingTimeInterval(5)
        while model.isRunning && Date() < failureDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if case .failure = model.state {} else { throw LocalBuildError.message("model must report validation failure") }
        try check(model.result == nil && model.showResult, "UI clears previous success and shows failure alert")
        print("Local build check passed")
    }
}

final class LocalMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
