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
    case deploy

    var displayName: String {
        switch self {
        case .test:
            return "检查连接"
        case .branches:
            return "刷新分支"
        case .deploy:
            return "切换并拉取"
        }
    }
}

enum RunState: Equatable {
    case idle
    case running(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle:
            return "等待操作"
        case let .running(message), let .success(message), let .failure(message):
            return message
        }
    }
}
