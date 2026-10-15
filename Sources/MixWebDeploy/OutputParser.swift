import Foundation

enum RemoteEvent: Equatable {
    case stage(RunStage)
    case message(String)
    case branches([String])
    case failure(String)
    case commit(String)
    case done
}

// Keep incomplete UTF-8 and protocol lines private until a whole line is available.
struct OutputParser {
    private var pending = Data()
    private var branchLines: [String]?
    private let redactor: LogRedactor

    init(settings: AppSettings) {
        redactor = LogRedactor(settings: settings)
    }

    mutating func append(_ data: Data, finished: Bool = false) -> [RemoteEvent] {
        pending.append(data)
        var events: [RemoteEvent] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if let event = parse(line) { events.append(event) }
        }
        if finished && !pending.isEmpty {
            if let event = parse(String(decoding: pending, as: UTF8.self)) { events.append(event) }
            pending.removeAll()
        }
        return events
    }

    private mutating func parse(_ text: String) -> RemoteEvent? {
        let line = Self.removeANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "__MWD_BRANCHES_BEGIN__" {
            branchLines = []
        } else if line == "__MWD_BRANCHES_END__", let lines = branchLines {
            branchLines = nil
            return .branches(Array(Set(lines)).sorted())
        } else if line.hasPrefix("__MWD_ERROR__:") {
            branchLines = nil
            return .failure(redactor.redact(String(line.dropFirst("__MWD_ERROR__:".count))))
        } else if branchLines != nil {
            if ConfigValidator.isValidBranch(line) { branchLines?.append(line) }
        } else if line.hasPrefix("__MWD_STAGE__:"),
                  let stage = RunStage(rawValue: String(line.dropFirst("__MWD_STAGE__:".count))) {
            return .stage(stage)
        } else if line.hasPrefix("__MWD_COMMIT__:") {
            let sha = String(line.dropFirst("__MWD_COMMIT__:".count))
            if sha.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                return .commit(sha)
            }
        } else if line == "__MWD_DONE__" {
            return .done
        } else if !line.isEmpty && !line.contains("__MWD_") {
            return .message(redactor.redact(line))
        }
        return nil
    }

    static func removeANSI(_ text: String) -> String {
        let pattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

struct LogRedactor {
    private let replacements: [(String, String)]

    init(settings: AppSettings) {
        let keyURL = URL(fileURLWithPath: settings.privateKeyPath)
        replacements = [
            (settings.privateKeyPath, "[私钥路径]"),
            (settings.privateKeyPath.isEmpty ? "" : keyURL.lastPathComponent, "[私钥文件]"),
            (settings.projectPath, "[项目目录]"),
            (settings.username, "[SSH 用户]"),
            (settings.host, "[SSH 主机]")
        ].filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
    }

    func redact(_ text: String) -> String {
        var result = OutputParser.removeANSI(text)
        for (value, label) in replacements {
            result = result.replacingOccurrences(of: value, with: label, options: .caseInsensitive)
        }
        for (pattern, label) in [
            (#"(?:ssh|https?|git)://[^\s'\"]+"#, "[远程地址]"),
            (#"[A-Za-z0-9._%+@-]+@[A-Za-z0-9.-]+(?::[^\s'\"]+)?"#, "[远程用户/地址]"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, "[IP 地址]"),
            (#"/(?:Users|home|private|tmp|var|data)/[^\s'\"]+"#, "[文件路径]")
        ] {
            result = result.replacingOccurrences(of: pattern, with: label, options: .regularExpression)
        }
        return result
    }
}
