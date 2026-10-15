import Darwin
import Foundation

enum LocalBuildError: LocalizedError {
    case message(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        case .cancelled: return "本地打包已停止，未替换 main.min.js。"
        }
    }
}

// The only mutable value is protected by lock across the UI and build queues.
final class LocalBuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw LocalBuildError.cancelled }
    }
}

struct LocalBuildProcess {
    let cancellation: LocalBuildCancellation

    // An output file avoids pipe deadlocks when npm or webpack produces a lot of output.
    func run(_ executable: String, _ arguments: [String], in directory: URL,
             timeout: TimeInterval = 30, onOutput: (String) -> Void = { _ in }) throws -> String {
        try cancellation.check()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ads-build-output-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw LocalBuildError.message("无法创建本地构建日志。")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FileHandle(forWritingTo: url)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? writer.close(); try? reader.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = writer
        process.standardError = writer
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["CI"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        var tail = ""

        func readOutput(finished: Bool = false) throws {
            while let data = try reader.read(upToCount: 65_536), !data.isEmpty {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    tail = String((tail + line + "\n").suffix(12_000))
                    onOutput(line)
                }
                if pending.count > 16_384 { pending = Data(pending.suffix(4_096)) }
            }
            if finished, !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                tail = String((tail + line).suffix(12_000))
                onOutput(line)
                pending.removeAll()
            }
        }

        do {
            while process.isRunning {
                try cancellation.check()
                guard Date() < deadline else {
                    throw LocalBuildError.message("命令执行超时（\(Int(timeout)) 秒），已停止，未替换 main.min.js。")
                }
                try readOutput()
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.waitUntilExit()
            try readOutput(finished: true)
            try cancellation.check()
            guard process.terminationStatus == 0 else {
                throw LocalBuildError.message("命令执行失败，退出码 \(process.terminationStatus)。\n\(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return tail.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            stopProcessTree(process)
            throw error
        }
    }

    private func stopProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        // npm launches tsc/webpack as children; stopping only npm leaves the build running.
        let listing = Process()
        let pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-axo", "pid=,ppid="]
        listing.standardOutput = pipe
        listing.standardError = FileHandle.nullDevice
        var children: [pid_t] = []
        do {
            try listing.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            listing.waitUntilExit()
            let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (pid_t, pid_t)? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
                return (pid, parent)
            }
            var parents = [process.processIdentifier]
            while !parents.isEmpty {
                let next = rows.filter { parents.contains($0.1) }.map(\.0)
                children += next
                parents = next
            }
        } catch {
            NSLog("本地构建停止：无法枚举子进程：%@", error.localizedDescription)
        }
        for pid in children.reversed() { kill(pid, SIGTERM) }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        for pid in children where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
