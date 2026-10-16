import Darwin
import Foundation

enum JSManagerCheck {
    @MainActor
    static func run(root: URL) async throws {
        let files = FileManager.default
        let store = JSArchiveStore(root: root.appendingPathComponent("JS archive"))
        let library = root.appendingPathComponent("manager target lib")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        let target = library.appendingPathComponent("main.min.js")
        let original = "module.exports = 'original';"
        let first = "throw new Error('parse only, never execute'); module.exports = 42;\n"
        let source = root.appendingPathComponent("v2.8.9.4_main.min.js")
        try original.write(to: target, atomically: true, encoding: .utf8)
        try first.write(to: source, atomically: true, encoding: .utf8)
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LocalBuildError.message("JS manager check failed: \(message)") }
        }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func mustFail(_ label: String, _ operation: () throws -> Void) throws {
            var failed = false
            do { try operation() } catch { failed = true }
            try check(failed, label)
        }

        let firstRecord = try store.archive(source, sourceKind: .build, note: "修复登录 CASE-123", branch: "feature/login")
        let repeated = try store.archive(source, sourceKind: .file, note: "相同版本的第二次测试")
        try check(firstRecord.id != repeated.id && firstRecord.sha256 == repeated.sha256, "same version and bytes retain separate records")
        try check(try text(target) == original, "archive alone never installs")
        try check(try store.load().artifacts.count == 2, "archive persists")
        try store.update(id: firstRecord.id, version: "v2.8.9.4-test", note: "验证窗口修复 CASE-123")
        let saved = try store.load().artifacts.first { $0.id == firstRecord.id }!
        try check(saved.matches("2.8.9.4 CASE-123") && saved.matches("feature/login") && !saved.matches("missing"), "version/note/branch search")
        try check(try JSArchiveStore(root: store.root).load().artifacts.first(where: { $0.id == saved.id })?.note == saved.note, "notes survive reload")

        let installed = try store.install(id: firstRecord.id, libraryPath: library.path, cancellation: LocalBuildCancellation()) { _ in }
        try check(try text(target) == first, "install selected version")
        try check(installed.backup != nil && (try text(installed.backup!)) == original, "installation preserves original backup")
        let backup = try store.load().backups.first!
        _ = try store.restore(id: backup.id, libraryPath: library.path, cancellation: LocalBuildCancellation()) { _ in }
        try check(try text(target) == original, "restore returns original bytes")
        try check(try store.load().backups.count == 2, "restore also backs up the current version")
        try "module.exports = 'tampered';".write(to: store.file(for: firstRecord), atomically: true, encoding: .utf8)
        try mustFail("tampered history must not install") {
            _ = try store.install(id: firstRecord.id, libraryPath: library.path, cancellation: LocalBuildCancellation()) { _ in }
        }
        try check(try text(target) == original, "tampered archive preserves target")
        try "module.exports = 'tampered backup';".write(to: URL(fileURLWithPath: backup.filePath), atomically: true, encoding: .utf8)
        try mustFail("tampered backup must not restore") {
            _ = try store.restore(id: backup.id, libraryPath: library.path, cancellation: LocalBuildCancellation()) { _ in }
        }
        try mustFail("wrong target must not restore") {
            _ = try store.restore(id: backup.id, libraryPath: root.path, cancellation: LocalBuildCancellation()) { _ in }
        }

        for (name, data) in [
            ("html", Data("<!doctype html><html>sign in</html>".utf8)),
            ("syntax", Data("function { broken".utf8)),
            ("empty", Data()),
            ("binary", Data([0, 255, 0, 1])),
            ("blank", Data(" \n ".utf8))
        ] {
            let bad = root.appendingPathComponent(name + ".js")
            try data.write(to: bad)
            let count = try store.load().artifacts.count
            try mustFail("reject \(name)") { _ = try store.archive(bad, sourceKind: .file, note: "") }
            try check(try store.load().artifacts.count == count, "invalid files never enter history")
        }
        let symlink = root.appendingPathComponent("symlink.js")
        try files.createSymbolicLink(at: symlink, withDestinationURL: source)
        try mustFail("reject symlink source") { _ = try store.archive(symlink, sourceKind: .file, note: "") }
        let lockFD = open(store.root.appendingPathComponent(".library.lock").path, O_RDWR)
        flock(lockFD, LOCK_EX | LOCK_NB)
        try mustFail("concurrent library mutation rejected") { try store.update(id: repeated.id, version: "race", note: "") }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        print("JS 库验证：独立历史、备注搜索、安装恢复、文件篡改、内容校验及互斥锁")

        let info = try JSFile.inspect(source)
        let fullURL = "https://version.adspower.net/software_dev/lib_testing/v2.8.9.4_main.min.js" + info.md5
        let spec = try JSDownloadSpec(fullURL)
        try check(spec.url.absoluteString == fullURL && spec.expectedMD5 == info.md5, "preserve entire hash-suffixed URL")
        for value in [
            "http://version.adspower.net/a.js", "https://evil.invalid/a.js",
            "https://version.adspower.net.evil.invalid/a.js", "https://user:pass@version.adspower.net/a.js",
            "https://version.adspower.net/admin/", "https://version.adspower.net/a.js#fragment"
        ] {
            try mustFail("reject unsupported download URL") { _ = try JSDownloadSpec(value) }
        }
        try mustFail("reject conflicting MD5") { _ = try JSDownloadSpec(fullURL, expectedMD5: String(repeating: "0", count: 32)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JSMockURLProtocol.self]
        let client = JSDownloadClient(configuration: configuration)
        JSMockURLProtocol.body = Data(first.utf8)
        JSMockURLProtocol.status = 200
        JSMockURLProtocol.mime = "application/javascript"
        let downloaded = try await client.download(spec) { _ in }
        defer { try? files.removeItem(at: downloaded) }
        try check(try text(downloaded) == first, "streamed download preserves bytes")
        try check(JSMockURLProtocol.request?.url?.absoluteString == fullURL, "GET uses full supplied URL")
        try check(JSMockURLProtocol.request?.httpMethod == "GET" &&
                  JSMockURLProtocol.request?.value(forHTTPHeaderField: "Cookie") == nil &&
                  JSMockURLProtocol.request?.value(forHTTPHeaderField: "Authorization") == nil, "download sends no browser cookies/credentials")
        _ = try store.archive(downloaded, filename: spec.filename, sourceKind: .download, note: "下载测试", expectedMD5: spec.expectedMD5)
        try mustFail("reject wrong downloaded checksum") {
            _ = try store.archive(downloaded, sourceKind: .download, note: "", expectedMD5: String(repeating: "0", count: 32))
        }
        for (status, mime, body) in [
            (404, "application/javascript", Data("not found".utf8)),
            (200, "text/html", Data("<html>login</html>".utf8)),
            (200, "application/json", Data(#"{"error":true}"#.utf8))
        ] {
            JSMockURLProtocol.status = status
            JSMockURLProtocol.mime = mime
            JSMockURLProtocol.body = body
            var failed = false
            do { let url = try await client.download(spec) { _ in }; try? files.removeItem(at: url) } catch { failed = true }
            try check(failed, "HTTP errors and error documents are rejected")
        }
        JSMockURLProtocol.status = 200
        JSMockURLProtocol.mime = "application/javascript"
        JSMockURLProtocol.body = Data(first.utf8)
        JSMockURLProtocol.delay = 2
        let pending = Task { try await client.download(spec) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        pending.cancel()
        var cancelled = false
        do { let url = try await pending.value; try? files.removeItem(at: url) } catch { cancelled = true }
        try check(cancelled, "download can be cancelled")
        JSMockURLProtocol.delay = 0
        print("下载验证：完整地址、MD5、GET、无登录信息、HTTP 错误及取消")

        let model = LocalBuildModel(defaults: LocalMemoryDefaults(), archiveRoot: root.appendingPathComponent("workbench model"), downloader: client)
        model.settings.libraryPath = library.path
        model.downloadURLText = fullURL
        model.note = "下载模型 CASE-456"
        model.download()
        try await wait(model)
        try check(model.records.count == 1 && model.records[0].source == .download && model.showResult, "download reaches UI history and alert")
        try check(try text(target) == original, "download never automatically installs")
        model.searchText = "CASE-456"
        try check(model.filteredRecords.count == 1, "UI searches notes")
        model.installSelected()
        try await wait(model)
        try check(model.installation != nil && (try text(target)) == first && model.availableBackups.count == 1, "UI installation records backup")
        model.restoreSelected()
        try await wait(model)
        try check(try text(target) == original && model.availableBackups.count == 2, "UI restores and retains reversible backup")
        print("界面模型验证：下载归档、备注搜索、安装与恢复完整流程")
    }

    @MainActor
    private static func wait(_ model: LocalBuildModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !model.isRunning else { model.stop(); throw LocalBuildError.message("界面模型操作超时") }
        if case let .failure(message) = model.state { throw LocalBuildError.message(message) }
    }
}

final class JSMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var body = Data()
    static var status = 200
    static var mime = "application/javascript"
    static var delay: TimeInterval = 0
    static var request: URLRequest?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        let body = Self.body
        let status = Self.status
        let mime = Self.mime
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime, "Content-Length": String(body.count)])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        if Self.delay == 0 { work.perform() } else { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: work) }
    }
    override func stopLoading() { work?.cancel() }
}
