import Darwin
import Foundation

struct BuildFileCopies {
    static let limit = 100 * 1024 * 1024
    let root: URL
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixWebDeploy/copied-js", isDirectory: true)
    }

    func create(projectPath: String, name: String, cancellation: LocalBuildCancellation) throws -> URL {
        let project = try BuildDirectory.project(projectPath)
        let lock = try BuildDirectoryLock(project: project)
        defer { lock.release() }
        let source = try BuildDirectory.file(in: project, name: name)
        let build = project.appendingPathComponent("build").path
        let cache = try BuildDirectory.physicalPath(root.path)
        guard cache != build, !cache.hasPrefix(build + "/") else { throw LocalBuildError.message("复制缓存不能位于 build 内。") }
        try ensureRoot()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            try copy(source, to: target, cancellation: cancellation)
            _ = try BuildDirectory.file(in: project, name: name)
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func copy(_ source: URL, to target: URL, cancellation: LocalBuildCancellation) throws {
        try cancellation.check()
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LocalBuildError.message("JS 文件无法读取，可能已删除或正在被改写，请刷新后重试。") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size <= Self.limit else {
            throw LocalBuildError.message("只能复制不超过 100 MB 的普通 JS 文件。")
        }
        let output = open(target.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard output >= 0 else { throw LocalBuildError.message("无法创建 JS 文件副本，请检查本地缓存目录权限。") }
        defer { close(output) }
        let inputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let outputHandle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var size = 0
        while true {
            try cancellation.check()
            guard let data = try inputHandle.read(upToCount: 256 * 1024), !data.isEmpty else { break }
            size += data.count
            guard size <= Self.limit else { throw LocalBuildError.message("JS 文件超过 100 MB，已停止复制。") }
            try outputHandle.write(contentsOf: data)
        }
        var after = stat(); var current = stat()
        guard fstat(descriptor, &after) == 0, lstat(source.path, &current) == 0,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_ino == current.st_ino, before.st_dev == current.st_dev,
              before.st_size == after.st_size, size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LocalBuildError.message("JS 文件在复制时发生变化，未更新剪贴板，请刷新后重试。")
        }
        try cancellation.check()
    }

    // Retain ten recent snapshots and every file still referenced by the clipboard.
    func prune(preserving urls: [URL], now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try ensureRoot()
        let keep = Set(try urls.map { try BuildDirectory.physicalPath($0.deletingLastPathComponent().path) })
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
                return (url, values?.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
        for (index, entry) in entries.enumerated() where index >= 10 || now.timeIntervalSince(entry.1) > 7 * 86400 {
            if !keep.contains(try BuildDirectory.physicalPath(entry.0.path)) { try FileManager.default.removeItem(at: entry.0) }
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalBuildError.message("复制缓存必须是普通目录。") }
    }
}
