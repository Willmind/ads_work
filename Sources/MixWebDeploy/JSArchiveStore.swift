import Darwin
import Foundation

enum JSSource: String, Codable, Sendable {
    case build, download, file
    var title: String {
        switch self {
        case .build: return "本地打包"
        case .download: return "链接下载"
        case .file: return "文件导入"
        }
    }
}

struct JSArtifact: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    var version: String
    var note: String
    let source: JSSource
    let createdAt: Date
    let branch: String?
    let sha256: String
    let md5: String
    let size: Int

    func matches(_ query: String) -> Bool {
        let keywords = query.split(whereSeparator: \.isWhitespace)
        let text = [version, note, filename, branch ?? "", source.title].joined(separator: " ")
        return keywords.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

struct JSBackup: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String
    let targetPath: String
    let createdAt: Date
    let sha256: String
    let label: String
}

struct JSArchiveIndex: Codable, Sendable {
    var formatVersion = 1
    var artifacts: [JSArtifact] = []
    var backups: [JSBackup] = []
}

struct JSInstallation: Sendable {
    let destination: URL
    let backup: URL?
    let label: String
}

struct JSArchiveStore: Sendable {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MixWebDeploy/js-library", isDirectory: true)
    }

    func load() throws -> JSArchiveIndex {
        let url = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return JSArchiveIndex() }
        let result = try JSONDecoder().decode(JSArchiveIndex.self, from: Data(contentsOf: url))
        guard result.formatVersion == 1 else { throw LocalBuildError.message("本地 JS 库格式不兼容，未修改历史记录。") }
        return result
    }

    func file(for artifact: JSArtifact) -> URL {
        root.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(artifact.id.uuidString, isDirectory: true).appendingPathComponent("main.min.js")
    }

    func archive(_ source: URL, filename: String? = nil, sourceKind: JSSource, note: String,
                 branch: String? = nil, expectedMD5: String? = nil) throws -> JSArtifact {
        try withLock {
            let info = try JSFile.inspect(source)
            if let expectedMD5, info.md5.caseInsensitiveCompare(expectedMD5) != .orderedSame {
                throw LocalBuildError.message("下载文件的 MD5 与预期不一致，未归档或安装。")
            }
            let name = filename ?? source.lastPathComponent
            let artifact = JSArtifact(id: UUID(), filename: name, version: JSFile.version(in: name),
                                      note: String(note.prefix(4_000)), source: sourceKind, createdAt: Date(), branch: branch,
                                      sha256: info.sha256, md5: info.md5, size: info.size)
            let destination = file(for: artifact)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                guard try JSFile.inspect(destination, checkSyntax: false).sha256 == info.sha256 else {
                    throw LocalBuildError.message("归档文件校验失败，未保存记录。")
                }
                var index = try load()
                index.artifacts.insert(artifact, at: 0)
                try save(index)
                return artifact
            } catch {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                throw error
            }
        }
    }

    func update(id: UUID, version: String, note: String) throws {
        try withLock {
            var index = try load()
            guard let position = index.artifacts.firstIndex(where: { $0.id == id }) else {
                throw LocalBuildError.message("选中的 JS 记录不存在，请刷新。")
            }
            let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
            index.artifacts[position].version = value.isEmpty ? "未标记版本" : String(value.prefix(100))
            index.artifacts[position].note = String(note.prefix(4_000))
            try save(index)
        }
    }

    func install(id: UUID, libraryPath: String, cancellation: LocalBuildCancellation,
                 onStage: (RunStage) -> Void) throws -> JSInstallation {
        try withLock {
            var index = try load()
            guard let artifact = index.artifacts.first(where: { $0.id == id }) else {
                throw LocalBuildError.message("选中的 JS 记录不存在，请刷新。")
            }
            let source = file(for: artifact)
            guard try JSFile.inspect(source).sha256 == artifact.sha256 else {
                throw LocalBuildError.message("历史 JS 文件已被修改，校验失败，未安装。")
            }
            let destination = try JSFile.destination(in: libraryPath)
            let backup = try replace(source: source, checksum: artifact.sha256, destination: destination,
                                     label: "安装 \(artifact.version)", index: &index,
                                     cancellation: cancellation, onStage: onStage)
            return JSInstallation(destination: destination, backup: backup, label: artifact.version)
        }
    }

    func restore(id: UUID, libraryPath: String, cancellation: LocalBuildCancellation,
                 onStage: (RunStage) -> Void) throws -> JSInstallation {
        try withLock {
            var index = try load()
            guard let backup = index.backups.first(where: { $0.id == id }) else {
                throw LocalBuildError.message("备份记录不存在，请刷新。")
            }
            let destination = try JSFile.destination(in: libraryPath)
            guard URL(fileURLWithPath: backup.targetPath).resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() else {
                throw LocalBuildError.message("该备份属于其他目标目录，请先选择对应的 lib。")
            }
            let source = URL(fileURLWithPath: backup.filePath)
            guard try JSFile.inspect(source).sha256 == backup.sha256 else {
                throw LocalBuildError.message("备份文件已被修改，校验失败，未恢复。")
            }
            let newBackup = try replace(source: source, checksum: backup.sha256, destination: destination,
                                        label: "恢复备份前", index: &index, cancellation: cancellation, onStage: onStage)
            return JSInstallation(destination: destination, backup: newBackup, label: "备份已恢复")
        }
    }

    private func replace(source: URL, checksum: String, destination: URL, label: String,
                         index: inout JSArchiveIndex, cancellation: LocalBuildCancellation,
                         onStage: (RunStage) -> Void) throws -> URL? {
        try JSInstaller(cancellation: cancellation).install(source, destination: destination, checksum: checksum, onStage: onStage) { url in
            let info = try JSFile.inspect(url, checkSyntax: false)
            index.backups.insert(JSBackup(id: UUID(), filePath: url.path, targetPath: destination.path,
                                          createdAt: Date(), sha256: info.sha256, label: label), at: 0)
            try save(index)
        }
    }

    private func save(_ index: JSArchiveIndex) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private func withLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent(".library.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw LocalBuildError.message("本地 JS 库不可写。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LocalBuildError.message("另一个窗口正在操作 JS 库，请稍后重试。")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}
