import Darwin
import Foundation

struct LocalBuildSettings: Codable, Equatable {
    var projectPath: String
    var libraryPath: String

    static var defaults: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            projectPath: home.appendingPathComponent("Desktop/code/mix_client").path,
            libraryPath: home.appendingPathComponent("Library/Application Support/adspower_global/cwd_global/lib").path
        )
    }
}

struct LocalBuildResult {
    let branch: String
    let artifact: URL
    let destination: URL
    let backup: URL?
    let checksum: String
    var didInstall = true
}

enum LocalBuildEvent {
    case stage(RunStage)
    case message(String)
    case completed(LocalBuildResult)
    case failed(Error)
}

struct LocalBuildService {
    static let stages: [RunStage] = [.localCheck, .build, .artifact, .backup, .replace, .complete]
    private let files = FileManager.default
    let cancellation: LocalBuildCancellation
    // Paths are supplied via Process.currentDirectoryURL, never shell interpolation.
    static let buildCommand = #"""
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            . "$NVM_DIR/nvm.sh" --no-use
            nvm use --silent default || exit 1
        fi
    fi
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo '找不到 Node.js/npm，请先安装 Node.js 或设置 nvm 的 default 版本。' >&2
        exit 127
    fi
    exec npm run buildLb
    """#

    func run(settings: LocalBuildSettings, installAfterBuild: Bool = true, onEvent: (LocalBuildEvent) -> Void) throws -> LocalBuildResult {
        onEvent(.stage(.localCheck))
        let project = try BuildDirectory.project(settings.projectPath)
        let library = URL(fileURLWithPath: settings.libraryPath, isDirectory: true).standardizedFileURL
        let destination = installAfterBuild
            ? try JSFile.destination(in: settings.libraryPath)
            : library.appendingPathComponent("main.min.js")
        let buildLock = try BuildDirectoryLock(project: project)
        defer { buildLock.release() }
        let process = LocalBuildProcess(cancellation: cancellation)
        let gitRoot = try process.run("/usr/bin/git", ["rev-parse", "--show-toplevel"], in: project)
        guard URL(fileURLWithPath: gitRoot).resolvingSymlinksInPath().standardizedFileURL.path == project.resolvingSymlinksInPath().path else {
            throw LocalBuildError.message("本地项目目录必须是 Git 仓库根目录。")
        }
        let branch = try process.run("/usr/bin/git", ["branch", "--show-current"], in: project)
        guard !branch.isEmpty else { throw LocalBuildError.message("当前处于 detached HEAD，请先切换到本地分支。") }
        let revision = try process.run("/usr/bin/git", ["rev-parse", "HEAD"], in: project)
        onEvent(.message("当前分支：\(branch) · \(revision.prefix(8))；包含本地未提交修改。"))

        let build = project.appendingPathComponent("build", isDirectory: true)
        guard build.resolvingSymlinksInPath() != library.resolvingSymlinksInPath() else {
            throw LocalBuildError.message("目标 lib 不能与项目 build 目录相同。")
        }
        try files.createDirectory(at: build, withIntermediateDirectories: true)
        guard try build.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LocalBuildError.message("build 目录不能是符号链接。")
        }
        let stash = build.appendingPathComponent(".ads-work-previous-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stash, withIntermediateDirectories: false)
        do {
            // Without old bundles webpack must emit a fresh file, even with the same version.
            for old in try artifacts(in: build) {
                try files.moveItem(at: old, to: stash.appendingPathComponent(old.lastPathComponent))
            }
            onEvent(.stage(.build))
            onEvent(.message("执行 npm run buildLb；旧产物已暂存，打包失败会恢复。"))
            _ = try process.run("/bin/zsh", ["-c", Self.buildCommand], in: project, timeout: 900) {
                onEvent(.message($0))
            }
            onEvent(.stage(.artifact))
            try cancellation.check()
            guard try process.run("/usr/bin/git", ["branch", "--show-current"], in: project) == branch,
                  try process.run("/usr/bin/git", ["rev-parse", "HEAD"], in: project) == revision else {
                throw LocalBuildError.message("打包期间分支或提交发生变化，已停止替换，请重新打包。")
            }
            let candidates = try artifacts(in: build)
            guard candidates.count == 1, let artifact = candidates.first else {
                throw LocalBuildError.message("本次打包应生成唯一的 *_main.min.js（或 main.min.js），实际找到 \(candidates.count) 个；未替换目标。")
            }
            guard (try artifact.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else {
                throw LocalBuildError.message("本次产物为空，未替换目标。")
            }
            let checksum = try JSFile.inspect(artifact).sha256
            onEvent(.message("本次产物：\(artifact.lastPathComponent) · SHA-256 \(checksum)"))
            // Restore historic versions before installing. Keep this run's version fresh.
            try restore(stash: stash, build: build, excluding: artifact.lastPathComponent)
            try cancellation.check()
            let backup = installAfterBuild
                ? try JSInstaller(cancellation: cancellation).install(artifact, destination: destination, checksum: checksum) { onEvent(.stage($0)) }
                : nil
            return LocalBuildResult(branch: branch, artifact: artifact, destination: destination, backup: backup, checksum: checksum,
                                    didInstall: installAfterBuild)
        } catch {
            do {
                try restore(stash: stash, build: build)
            } catch let restoreError {
                throw LocalBuildError.message("\(error.localizedDescription)\n恢复旧产物失败：\(restoreError.localizedDescription)。暂存目录：\(stash.path)")
            }
            throw error
        }
    }

    private func artifacts(in build: URL) throws -> [URL] {
        try files.contentsOfDirectory(at: build, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent == "main.min.js" || $0.lastPathComponent.hasSuffix("_main.min.js") }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LocalBuildError.message("主 JS 产物必须是普通文件：\(url.lastPathComponent)")
                }
                return url
            }
    }

    private func restore(stash: URL, build: URL, excluding: String? = nil) throws {
        guard files.fileExists(atPath: stash.path) else { return }
        for old in try files.contentsOfDirectory(at: stash, includingPropertiesForKeys: nil) {
            let destination = build.appendingPathComponent(old.lastPathComponent)
            if old.lastPathComponent == excluding { continue }
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: old, to: destination)
        }
        try files.removeItem(at: stash)
    }

}
