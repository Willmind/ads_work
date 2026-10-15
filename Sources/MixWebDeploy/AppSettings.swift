import Foundation

struct AppSettings: Codable, Equatable {
    var host: String
    var port: String
    var username: String
    var privateKeyPath: String
    var projectPath: String
    var firstMenuChoice: String
    var secondMenuChoice: String
    var branch: String

    func hasSameConnection(as other: AppSettings) -> Bool {
        var lhs = self
        var rhs = other
        lhs.branch = ""
        rhs.branch = ""
        return lhs == rhs
    }

    static var defaults: AppSettings {
        return AppSettings(
            host: "",
            port: "22",
            username: "",
            privateKeyPath: "",
            projectPath: "",
            firstMenuChoice: "1",
            secondMenuChoice: "1",
            branch: ""
        )
    }
}

enum RemoteAction: String {
    case test
    case branches
    case syncBranches
    case deploy

    var displayName: String {
        switch self {
        case .test:
            return "检查连接"
        case .branches:
            return "刷新分支"
        case .syncBranches:
            return "同步远程"
        case .deploy:
            return "切换并拉取"
        }
    }
}

extension RemoteAction {
    var stages: [RunStage] {
        switch self {
        case .test: return [.connect, .complete]
        case .branches: return [.connect, .project, .branches, .complete]
        case .syncBranches: return [.connect, .project, .fetch, .branches, .complete]
        case .deploy: return [.connect, .project, .fetch, .check, .checkout, .pull, .complete]
        }
    }
}

enum RunStage: String {
    case connect, project, fetch, branches, check, checkout, pull, complete
    case localCheck, build, artifact, backup, replace

    var title: String {
        switch self {
        case .connect: return "连接服务器"
        case .project: return "进入项目"
        case .fetch: return "同步远程"
        case .branches: return "读取分支"
        case .check: return "检查工作区"
        case .checkout: return "切换分支"
        case .pull: return "拉取代码"
        case .complete: return "完成"
        case .localCheck: return "检查本地项目"
        case .build: return "打包当前分支"
        case .artifact: return "校验产物"
        case .backup: return "备份原文件"
        case .replace: return "替换主文件"
        }
    }
}

enum RunState: Equatable {
    case idle
    case running(String)
    case success(String)
    case failure(String)
    case cancelled

    var message: String {
        switch self {
        case .idle:
            return "等待操作"
        case .cancelled:
            return "操作已停止"
        case let .running(message), let .success(message), let .failure(message):
            return message
        }
    }
}
