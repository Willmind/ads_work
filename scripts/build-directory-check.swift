import Foundation

enum BuildDirectoryCheck {
    static func run(in root: URL) throws {
        let manager = FileManager.default
        let project = root.appendingPathComponent("directory project")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"scripts":{"buildLb":"node fixture.js"}}"#.write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let build = project.appendingPathComponent("build")
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LocalBuildError.message("Build directory check: \(label)") }
            checks += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw LocalBuildError.message("Expected rejection: \(label)")
        }
        func write(_ relative: String, _ content: String = "module.exports=1;") throws {
            let url = build.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let missing = try BuildDirectory.read(project.path)
        try check(!missing.exists && missing.files.isEmpty, "missing build is an empty state")
        try check(!manager.fileExists(atPath: build.path), "read does not create build")
        try write("main.js"); try write("chunks/second.JS"); try write("main.js.map", "map")
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: build.appendingPathComponent("main.js").path)
        let snapshot = try BuildDirectory.read(project.path)
        try check(snapshot.files.count == 2 && snapshot.entryCount == 4, "only JS files, recursively")
        try check(snapshot.files.first?.name == "chunks/second.JS", "newest file first, relative name")
        try check(snapshot.files.allSatisfy { $0.size > 0 }, "file size metadata")
        try write("added.js")
        try check(try BuildDirectory.read(project.path).files.count == 3, "external creation is visible")
        try manager.removeItem(at: build.appendingPathComponent("added.js"))
        try check(try BuildDirectory.read(project.path).files.count == 2, "external deletion is visible")
        let lock = try BuildDirectoryLock(project: BuildDirectory.project(project.path))
        try rejects("concurrent build lock") { _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: LocalBuildCancellation()) }
        lock.release()
        try check(manager.fileExists(atPath: build.appendingPathComponent("main.js").path), "lock refusal preserves contents")
        try rejects("protected install path") { _ = try BuildDirectory.clear(project.path, protecting: [build.appendingPathComponent("lib").path], cancellation: LocalBuildCancellation()) }
        let alias = root.appendingPathComponent("project-alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: project)
        try rejects("protected path through parent symlink") { _ = try BuildDirectory.clear(project.path, protecting: [alias.appendingPathComponent("build/lib").path], cancellation: LocalBuildCancellation()) }
        try manager.removeItem(at: alias)
        let outside = root.appendingPathComponent("outside.js")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: build.appendingPathComponent("linked.js"), withDestinationURL: outside)
        try check(try BuildDirectory.read(project.path).files.count == 2, "linked JS is not followed")
        try rejects("nested symlink") { _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: LocalBuildCancellation()) }
        try check(manager.fileExists(atPath: build.appendingPathComponent("main.js").path), "preflight rejects before deleting any file")
        try check(try String(contentsOf: outside, encoding: .utf8) == "outside", "outside target untouched")
        try manager.removeItem(at: build.appendingPathComponent("linked.js"))
        try manager.createDirectory(at: build.appendingPathComponent(".ads-work-previous-test"), withIntermediateDirectories: false)
        try rejects("unresolved recovery directory") { _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: LocalBuildCancellation()) }
        try manager.removeItem(at: build.appendingPathComponent(".ads-work-previous-test"))
        let cancelled = LocalBuildCancellation(); cancelled.cancel()
        try rejects("cancel before deleting") { _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: cancelled) }
        try check(manager.fileExists(atPath: build.appendingPathComponent("main.js").path), "cancel preserves contents")
        let count = try BuildDirectory.clear(project.path, protecting: [outside.path], cancellation: LocalBuildCancellation())
        try check(count == 4 && manager.fileExists(atPath: build.path), "clear all files and subdirectories, keep build")
        try check(try manager.contentsOfDirectory(atPath: build.path).isEmpty, "clear removes non-JS too")
        try check(try String(contentsOf: outside, encoding: .utf8) == "outside", "clear preserves siblings")
        try check(!manager.fileExists(atPath: project.appendingPathComponent(".ads-work-build.lock").path), "clear releases shared lock")
        try manager.removeItem(at: build)
        try manager.createSymbolicLink(at: build, withDestinationURL: root)
        try rejects("build root symlink read") { _ = try BuildDirectory.read(project.path) }
        try rejects("build root symlink clear") { _ = try BuildDirectory.clear(project.path, protecting: [], cancellation: LocalBuildCancellation()) }
        try manager.removeItem(at: build)
        try rejects("invalid project") { _ = try BuildDirectory.read(root.path) }
        print("build 目录检查通过：\(checks) 项断言（读取、外部变更、清空边界、链接、保护目录与构建锁）。")
    }
}
