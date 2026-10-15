import CryptoKit
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

    func run(settings: LocalBuildSettings, onEvent: (LocalBuildEvent) -> Void) throws -> LocalBuildResult {
        onEvent(.stage(.localCheck))
        let project = try directory(settings.projectPath, label: "本地项目")
        let library = try directory(settings.libraryPath, label: "目标 lib")
        let destination = library.appendingPathComponent("main.min.js")
        guard files.isWritableFile(atPath: library.path) else {
            throw LocalBuildError.message("目标 lib 目录不可写，请检查目录权限。")
        }
        try validateDestination(destination)
        let packageURL = project.appendingPathComponent("package.json")
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL)) as? [String: Any]
        guard let scripts = package?["scripts"] as? [String: String], scripts["buildLb"] != nil else {
            throw LocalBuildError.message("项目 package.json 中没有 buildLb 脚本。")
        }
        let lockURL = project.appendingPathComponent(".ads-work-build.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard descriptor >= 0 else {
            throw LocalBuildError.message("无法取得构建锁，可能已有打包任务。若上次应用异常退出，请确认没有构建进程，再删除项目内 .ads-work-build.lock。")
        }
        close(descriptor)
        defer { try? files.removeItem(at: lockURL) }
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
            let checksum = try digest(artifact)
            onEvent(.message("本次产物：\(artifact.lastPathComponent) · SHA-256 \(checksum)"))
            // Restore historic versions before installing. Keep this run's version fresh.
            try restore(stash: stash, build: build, excluding: artifact.lastPathComponent)
            try cancellation.check()
            let backup = try install(artifact, destination: destination, checksum: checksum, onEvent: onEvent)
            return LocalBuildResult(branch: branch, artifact: artifact, destination: destination, backup: backup, checksum: checksum)
        } catch {
            do {
                try restore(stash: stash, build: build)
            } catch let restoreError {
                throw LocalBuildError.message("\(error.localizedDescription)\n恢复旧产物失败：\(restoreError.localizedDescription)。暂存目录：\(stash.path)")
            }
            throw error
        }
    }

    private func directory(_ path: String, label: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw LocalBuildError.message("\(label)目录必须是绝对路径。")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LocalBuildError.message("\(label)目录不存在。")
        }
        return url
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

    private func validateDestination(_ url: URL) throws {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw LocalBuildError.message("目标 main.min.js 必须是普通文件，不能是目录或符号链接。")
        }
    }

    private func install(_ artifact: URL, destination: URL, checksum: String,
                         onEvent: (LocalBuildEvent) -> Void) throws -> URL? {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".main-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: artifact, to: temporary)
        guard try digest(temporary) == checksum else { throw LocalBuildError.message("复制后的 JS 校验失败，未替换目标。") }
        try cancellation.check()
        onEvent(.stage(.backup))
        try validateDestination(destination)
        var backup: URL?
        if files.fileExists(atPath: destination.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = destination.appendingPathExtension("backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
            try files.copyItem(at: destination, to: url)
            guard try digest(url) == digest(destination) else {
                throw LocalBuildError.message("原文件备份校验失败，未替换目标。")
            }
            let attributes = try files.attributesOfItem(atPath: destination.path)
            if let permissions = attributes[.posixPermissions] {
                try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            backup = url
            onEvent(.message("原 main.min.js 已备份。"))
        }
        try cancellation.check()
        onEvent(.stage(.replace))
        // Same-directory rename is atomic; failures leave the existing file intact.
        guard rename(temporary.path, destination.path) == 0 else {
            throw LocalBuildError.message("替换 main.min.js 失败：\(String(cString: strerror(errno)))。原文件仍保留。")
        }
        return backup
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
