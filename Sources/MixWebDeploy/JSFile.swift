import CryptoKit
import Darwin
import Foundation
import JavaScriptCore

struct JSFileInfo: Sendable {
    let sha256: String
    let md5: String
    let size: Int
}

enum JSFile {
    static let maximumSize = 100 * 1_024 * 1_024

    static func inspect(_ url: URL, checkSyntax: Bool = true) throws -> JSFileInfo {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalBuildError.message("JS 必须是普通文件，不能是目录或符号链接。")
        }
        guard let size = values.fileSize, size > 0, size <= maximumSize else {
            throw LocalBuildError.message("JS 文件不能为空，且不能超过 100 MB。")
        }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw LocalBuildError.message("读取期间文件发生变化，请重试。") }
        if checkSyntax {
            guard var source = String(data: data, encoding: .utf8), !source.contains("\0") else {
                throw LocalBuildError.message("文件不是有效的 UTF-8 JavaScript。")
            }
            let beginning = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !beginning.hasPrefix("<"), !beginning.isEmpty else {
                throw LocalBuildError.message("下载内容是网页或空白内容，不能安装为 JS。")
            }
            if source.hasPrefix("#!"), let newline = source.firstIndex(of: "\n") {
                source = String(source[newline...])
            }
            // Parse only. Never execute imported or downloaded JavaScript.
            guard let context = JSGlobalContextCreate(nil),
                  let script = JSStringCreateWithUTF8CString("function __ads_work_bundle__(){\n" + source + "\n}") else {
                throw LocalBuildError.message("无法启动 JS 语法校验。")
            }
            defer { JSGlobalContextRelease(context); JSStringRelease(script) }
            var exception: JSValueRef?
            guard JSCheckScriptSyntax(context, script, nil, 1, &exception) else {
                throw LocalBuildError.message("JavaScript 语法校验失败，请确认选择的是完整的主 JS 文件。")
            }
        }
        return JSFileInfo(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            size: size
        )
    }

    static func version(in filename: String) -> String {
        let pattern = #"(?i)^v?\d+(?:\.\d+){1,6}(?=_|[.-]main|$)"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else { return "未标记版本" }
        return String(filename[range])
    }

    static func destination(in path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw LocalBuildError.message("目标 lib 必须是绝对路径。")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            throw LocalBuildError.message("目标 lib 目录不存在或不可写，请重新选择。")
        }
        let target = directory.appendingPathComponent("main.min.js")
        try validateTarget(target)
        return target
    }

    static func validateTarget(_ target: URL) throws {
        if let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw LocalBuildError.message("目标 main.min.js 必须是普通文件，不能是目录或符号链接。")
        }
    }
}

struct JSInstaller {
    let cancellation: LocalBuildCancellation

    func install(_ source: URL, destination: URL, checksum: String,
                 onStage: (RunStage) -> Void = { _ in },
                 onBackup: (URL) throws -> Void = { _ in }) throws -> URL? {
        let files = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".main-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: temporary) }
        try cancellation.check()
        try JSFile.validateTarget(destination)
        try files.copyItem(at: source, to: temporary)
        guard try JSFile.inspect(temporary, checkSyntax: false).sha256 == checksum else {
            throw LocalBuildError.message("复制后的 JS 校验失败，未替换目标。")
        }
        try cancellation.check()
        onStage(.backup)
        var backup: URL?
        if files.fileExists(atPath: destination.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = destination.appendingPathExtension("backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
            try files.copyItem(at: destination, to: url)
            guard try JSFile.inspect(url, checkSyntax: false).sha256 == JSFile.inspect(destination, checkSyntax: false).sha256 else {
                throw LocalBuildError.message("原文件备份校验失败，未替换目标。")
            }
            let attributes = try files.attributesOfItem(atPath: destination.path)
            if let permissions = attributes[.posixPermissions] {
                try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            // Persist the recoverable backup before committing the replacement.
            try onBackup(url)
            backup = url
        }
        try cancellation.check()
        onStage(.replace)
        try JSFile.validateTarget(destination)
        guard rename(temporary.path, destination.path) == 0 else {
            throw LocalBuildError.message("替换 main.min.js 失败：\(String(cString: strerror(errno)))。原文件仍保留。")
        }
        return backup
    }
}
