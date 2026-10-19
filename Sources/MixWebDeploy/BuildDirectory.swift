import Darwin
import Foundation

struct BuildDirectoryFile {
    let name: String
    let size: Int
    let modifiedAt: Date
}

struct BuildDirectorySnapshot {
    let path: String
    let exists: Bool
    let entryCount: Int
    let files: [BuildDirectoryFile]
}

final class BuildDirectoryLock {
    private let url: URL
    private var descriptor: Int32

    init(project: URL) throws {
        url = project.appendingPathComponent(".ads-work-build.lock")
        descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard descriptor >= 0 else {
            throw LocalBuildError.message("无法取得构建锁，可能已有打包或清空任务。若上次应用异常退出，请确认没有构建进程，再删除项目内 .ads-work-build.lock。")
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        try? FileManager.default.removeItem(at: url)
    }

    deinit { release() }
}

enum BuildDirectory {
    private static let manager = FileManager.default
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    static func project(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw LocalBuildError.message("请选择有效的本地项目绝对路径。") }
        let selected = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalBuildError.message("项目根目录必须是普通目录，不能是符号链接。") }
        let root = URL(fileURLWithPath: try physicalPath(selected.path), isDirectory: true)
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("package.json"))) as? [String: Any]
        guard let scripts = package?["scripts"] as? [String: Any], scripts["buildLb"] is String else {
            throw LocalBuildError.message("项目 package.json 中没有 buildLb 脚本。")
        }
        return root
    }

    static func read(_ path: String) throws -> BuildDirectorySnapshot {
        let root = try project(path).appendingPathComponent("build", isDirectory: true)
        guard try exists(root) else { return BuildDirectorySnapshot(path: root.path, exists: false, entryCount: 0, files: []) }
        try requireDirectory(root)
        let entries = try walk(root, strict: false)
        let files = entries.compactMap { url, values, name -> BuildDirectoryFile? in
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "js" else { return nil }
            return BuildDirectoryFile(name: name, size: values.fileSize ?? 0,
                                      modifiedAt: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.modifiedAt == $1.modifiedAt ? $0.name < $1.name : $0.modifiedAt > $1.modifiedAt }
        return BuildDirectorySnapshot(path: root.path, exists: true, entryCount: entries.count, files: files)
    }

    static func file(in project: URL, name: String) throws -> URL {
        let components = name.components(separatedBy: "/")
        guard !name.contains("\0"), !name.contains("\\"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".ads-work-previous-") }),
              (name as NSString).pathExtension.lowercased() == "js" else {
            throw LocalBuildError.message("请选择 build 列表中的 JS 文件。")
        }
        var source = project.appendingPathComponent("build", isDirectory: true)
        try requireDirectory(source)
        for component in components.dropLast() { source.appendPathComponent(component, isDirectory: true); try requireDirectory(source) }
        source.appendPathComponent(components.last!)
        let values = try source.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalBuildError.message("JS 文件已变化或不是普通文件，请刷新后重试。")
        }
        return source
    }

    static func clear(_ path: String, protecting paths: [String], cancellation: LocalBuildCancellation) throws -> Int {
        let project = try project(path)
        let lock = try BuildDirectoryLock(project: project)
        defer { lock.release() }
        let root = project.appendingPathComponent("build", isDirectory: true)
        guard try exists(root) else { return 0 }
        try requireDirectory(root)
        for path in paths where path.hasPrefix("/") {
            let protected = try physicalPath(path)
            guard protected != root.path, !protected.hasPrefix(root.path + "/") else {
                throw LocalBuildError.message("build 内包含已配置的安装目录或 JS 历史库，已拒绝清空。")
            }
        }
        // Validate the whole tree before deleting anything; never traverse a link.
        let entries = try walk(root, strict: true)
        var count = 0
        for (url, values, name) in entries.reversed() {
            try cancellation.check()
            try requireDirectory(root)
            var parent = root
            for component in name.split(separator: "/").dropLast() {
                parent.appendPathComponent(String(component), isDirectory: true)
                try requireDirectory(parent)
            }
            guard try exists(url) else { continue }
            let current = try url.resourceValues(forKeys: keys)
            guard current.isSymbolicLink != true, current.isDirectory == values.isDirectory else {
                throw LocalBuildError.message("build 内容在清空时发生变化，已停止；部分文件可能已删除。")
            }
            let result = values.isDirectory == true ? rmdir(url.path) : unlink(url.path)
            guard result == 0 else { throw LocalBuildError.message("清空未完成，请检查文件权限或占用后重试；部分文件可能已删除。") }
            count += 1
        }
        return count
    }

    static func physicalPath(_ path: String) throws -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let resolved = realpath(normalized, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard errno == ENOENT else { throw LocalBuildError.message("无法解析目录路径，请检查权限或目录链接。") }
        let url = URL(fileURLWithPath: normalized)
        guard url.path != "/" else { throw LocalBuildError.message("无法解析目录路径。") }
        return try physicalPath(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    private static func exists(_ url: URL) throws -> Bool {
        do { _ = try manager.attributesOfItem(atPath: url.path); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LocalBuildError.message("build 及其子目录必须是普通目录，不能是符号链接。")
        }
    }

    private static func walk(_ root: URL, strict: Bool) throws -> [(URL, URLResourceValues, String)] {
        var result: [(URL, URLResourceValues, String)] = []
        var pending: [(URL, Int, String)] = [(root, 0, "")]
        while let (directory, depth, prefix) = pending.popLast() {
            guard depth < 64, result.count < 20000 else { throw LocalBuildError.message("build 内容过多或层级过深，已停止读取或清空。") }
            try requireDirectory(directory)
            for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                let item = directory.appendingPathComponent(entry.lastPathComponent)
                let name = prefix + entry.lastPathComponent
                guard result.count < 20000 else { throw LocalBuildError.message("build 内容过多，已停止读取或清空。") }
                guard let values = try? item.resourceValues(forKeys: keys) else {
                    if strict { throw LocalBuildError.message("build 内容正在变化，未开始清空，请稍后重试。") }
                    continue
                }
                let recovery = item.lastPathComponent.hasPrefix(".ads-work-previous-")
                if recovery || values.isSymbolicLink == true || (values.isDirectory != true && values.isRegularFile != true) {
                    if strict { throw LocalBuildError.message("build 含符号链接、特殊文件或旧产物恢复目录，未开始清空，请先检查。") }
                    continue
                }
                result.append((item, values, name))
                if values.isDirectory == true { pending.append((item, depth + 1, name + "/")) }
            }
        }
        return result
    }
}
