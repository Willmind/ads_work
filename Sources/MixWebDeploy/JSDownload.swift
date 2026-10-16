import Foundation

struct JSDownloadSpec: Sendable {
    let url: URL
    let filename: String
    let expectedMD5: String?

    init(_ text: String, expectedMD5: String = "") throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), Self.isAllowed(url), url.fragment == nil else {
            throw LocalBuildError.message("请粘贴后台复制的完整 HTTPS 下载链接（version.adspower.net），不要粘贴后台页面地址。")
        }
        let name = url.lastPathComponent
        guard name.range(of: #"\.js(?:[a-fA-F0-9]{32})?$"#, options: .regularExpression) != nil else {
            throw LocalBuildError.message("链接应指向 JS 文件；支持 .js 后附带 MD5 的完整地址。")
        }
        let supplied = expectedMD5.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supplied.isEmpty || supplied.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw LocalBuildError.message("MD5 应为 32 位十六进制字符，也可以留空。")
        }
        let embedded = name.range(of: #"(?<=\.js)[a-fA-F0-9]{32}$"#, options: .regularExpression).map { String(name[$0]).lowercased() }
        guard supplied.isEmpty || embedded == nil || supplied == embedded else {
            throw LocalBuildError.message("手动填写的 MD5 与链接中的 MD5 不一致。")
        }
        self.url = url
        filename = name
        self.expectedMD5 = supplied.isEmpty ? embedded : supplied
    }

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "version.adspower.net"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

struct JSDownloadClient {
    var configuration: URLSessionConfiguration = .ephemeral

    func download(_ spec: JSDownloadSpec, onProgress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let transfer = try JSDownloadTransfer(spec: spec, configuration: configuration, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: {
            transfer.cancel()
        }
    }
}

// Delegate callbacks use one serial queue. The lock only protects start/cancel races.
private final class JSDownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let spec: JSDownloadSpec
    private let configuration: URLSessionConfiguration
    private let onProgress: @Sendable (String) -> Void
    private let file: URL
    private let writer: FileHandle
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?
    private var received = 0
    private var expected: Int64 = 0
    private var redirects = 0
    private var lastProgress = Date.distantPast

    init(spec: JSDownloadSpec, configuration: URLSessionConfiguration,
         onProgress: @escaping @Sendable (String) -> Void) throws {
        self.spec = spec
        self.configuration = configuration
        self.onProgress = onProgress
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ads-js-download-\(UUID().uuidString).js")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw LocalBuildError.message("无法创建下载临时文件。")
        }
        writer = try FileHandle(forWritingTo: file)
    }

    func start(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: spec.url)
        request.httpMethod = "GET"
        request.setValue("application/javascript, text/javascript, application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        task.resume()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = LocalBuildError.message("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，未保存或安装。")
            completionHandler(.cancel)
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        guard !mime.contains("html"), !mime.contains("json"), !mime.contains("xml"),
              response.expectedContentLength <= Int64(JSFile.maximumSize) else {
            failure = LocalBuildError.message("服务器返回网页、错误内容或超过 100 MB 的文件，已停止下载。")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= JSFile.maximumSize else {
            failure = LocalBuildError.message("下载超过 100 MB，已停止，未保存或安装。")
            dataTask.cancel()
            return
        }
        do { try writer.write(contentsOf: data) } catch {
            failure = error
            dataTask.cancel()
        }
        if Date().timeIntervalSince(lastProgress) > 0.3 {
            let downloaded = String(format: "%.1f", Double(received) / 1_048_576)
            let suffix = expected > 0 ? " / \(String(format: "%.1f", Double(expected) / 1_048_576)) MB" : " MB"
            onProgress("已下载 \(downloaded)\(suffix)")
            lastProgress = Date()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, JSDownloadSpec.isAllowed(url) else {
            failure = LocalBuildError.message("下载地址跳转到不支持的域名或跳转次数过多，已停止。")
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpMethod = "GET"
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try writer.close() } catch { if failure == nil { failure = error } }
        lock.lock()
        let wasCancelled = cancelled
        let completion = continuation
        continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error = failure ?? (wasCancelled ? LocalBuildError.cancelled : error) {
            try? FileManager.default.removeItem(at: file)
            completion?.resume(throwing: error)
        } else {
            completion?.resume(returning: file)
        }
    }
}
