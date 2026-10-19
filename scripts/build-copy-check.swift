import Foundation

enum BuildCopyCheck {
    static func run(in root: URL) throws {
        let manager = FileManager.default
        let project = root.appendingPathComponent("copy project")
        let build = project.appendingPathComponent("build")
        let source = build.appendingPathComponent("chunks/中文 file #1.js")
        try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"scripts":{"buildLb":"node fixture.js"}}"#.write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let bytes = Data("module.exports='完整 JS';".utf8)
        try bytes.write(to: source)
        let cache = BuildFileCopies(root: root.appendingPathComponent("copy cache"))
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LocalBuildError.message("Build copy check: \(message)") }; checks += 1
        }
        func reject(_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw LocalBuildError.message("Expected build copy rejection")
        }
        func create(_ name: String) throws -> URL {
            try cache.create(projectPath: project.path, name: name, cancellation: LocalBuildCancellation())
        }
        let copied = try create("chunks/中文 file #1.js")
        try check(copied.lastPathComponent == source.lastPathComponent, "原文件名与 Unicode 保留")
        try check(try Data(contentsOf: copied) == bytes, "字节完全一致")
        try Data("changed".utf8).write(to: source)
        try check(try Data(contentsOf: copied) == bytes, "独立副本不随 build 变化")
        let newCopy = try create("chunks/中文 file #1.js")
        try check(newCopy != copied, "同名复制使用独立路径")
        for name in ["../outside.js", "/outside.js", "chunks/../outside.js", "chunks\\outside.js", "", "a.txt", ".ads-work-previous-test/x.js", "missing.js"] {
            try reject { _ = try create(name) }
        }
        let lock = try BuildDirectoryLock(project: BuildDirectory.project(project.path))
        try reject { _ = try create("chunks/中文 file #1.js") }; lock.release()
        let outside = root.appendingPathComponent("copy outside.js"); try bytes.write(to: outside)
        try manager.createSymbolicLink(at: build.appendingPathComponent("linked.js"), withDestinationURL: outside)
        try reject { _ = try create("linked.js") }
        try manager.removeItem(at: build.appendingPathComponent("linked.js"))
        try manager.createSymbolicLink(at: build.appendingPathComponent("linked-dir"), withDestinationURL: source.deletingLastPathComponent())
        try reject { _ = try create("linked-dir/中文 file #1.js") }
        try manager.removeItem(at: build.appendingPathComponent("linked-dir"))
        let huge = build.appendingPathComponent("huge.js"); manager.createFile(atPath: huge.path, contents: Data())
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: UInt64(BuildFileCopies.limit + 1)); try handle.close()
        try reject { _ = try create("huge.js") }; try manager.removeItem(at: huge)
        let token = LocalBuildCancellation(); token.cancel()
        try reject { _ = try cache.create(projectPath: project.path, name: "chunks/中文 file #1.js", cancellation: token) }
        let inside = build.appendingPathComponent("cache")
        try reject { _ = try BuildFileCopies(root: inside).create(projectPath: project.path, name: "chunks/中文 file #1.js", cancellation: LocalBuildCancellation()) }
        try check(!manager.fileExists(atPath: inside.path), "拒绝在 build 内创建缓存")
        let alias = root.appendingPathComponent("copy cache alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: cache.root)
        try reject { _ = try BuildFileCopies(root: alias).create(projectPath: project.path, name: "chunks/中文 file #1.js", cancellation: LocalBuildCancellation()) }
        try manager.removeItem(at: alias)
        _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: LocalBuildCancellation())
        try check(try Data(contentsOf: copied) == bytes, "清空 build 后副本仍完整")
        let pasted = root.appendingPathComponent("pasted.js"); try manager.copyItem(at: copied, to: pasted)
        try check(try Data(contentsOf: pasted) == bytes, "清空后仍可复制粘贴到其他目录")
        let old = newCopy.deletingLastPathComponent()
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: copied.deletingLastPathComponent().path)
        let unrelated = cache.root.appendingPathComponent("unrelated"); try manager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try cache.prune(preserving: [copied])
        try check(!manager.fileExists(atPath: old.path), "清理过期未使用副本")
        try check(manager.fileExists(atPath: copied.path), "保留剪贴板引用的过期副本")
        try check(manager.fileExists(atPath: unrelated.path), "不清理非副本目录")
        for _ in 0..<12 {
            let dir = cache.root.appendingPathComponent(UUID().uuidString); try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            try bytes.write(to: dir.appendingPathComponent("file.js"))
        }
        try cache.prune(preserving: [copied])
        let kept = try manager.contentsOfDirectory(at: cache.root, includingPropertiesForKeys: []).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        try check(kept.count == 11 && manager.fileExists(atPath: copied.path), "保留最近十份及当前剪贴板副本")
        try check(!manager.fileExists(atPath: project.appendingPathComponent(".ads-work-build.lock").path), "复制结束释放构建锁")
        print("JS 文件副本检查通过：\(checks) 项断言（独立副本、清空后粘贴、边界、取消及缓存清理）。")
    }
}
