import Foundation

enum ConfigValidator {
    static func validate(settings: AppSettings, action: RemoteAction) -> String? {
        let fileManager = FileManager.default

        guard matches(settings.host, pattern: #"^[A-Za-z0-9.-]+$"#) else {
            return "SSH 主机名格式不正确。"
        }

        guard let port = Int(settings.port), (1...65_535).contains(port) else {
            return "SSH 端口必须是 1 到 65535 之间的数字。"
        }

        guard matches(settings.username, pattern: #"^[A-Za-z0-9._@+-]+$"#) else {
            return "SSH 用户名包含不支持的字符。"
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: settings.privateKeyPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: settings.privateKeyPath) else {
            return "找不到 PEM 私钥文件，或文件不可读。"
        }

        guard settings.projectPath.hasPrefix("/"),
              matches(settings.projectPath, pattern: #"^/[A-Za-z0-9._/-]+$"#),
              !settings.projectPath.contains("..") else {
            return "服务器项目目录必须是安全的绝对路径。"
        }

        guard matches(settings.firstMenuChoice, pattern: #"^[A-Za-z0-9._-]+$"#),
              matches(settings.secondMenuChoice, pattern: #"^[A-Za-z0-9._-]+$"#) else {
            return "Jumpserver 菜单选项格式不正确。"
        }

        if action == .deploy, !isValidBranch(settings.branch) {
            return "请输入有效的 Git 分支名。"
        }

        return nil
    }

    static func isValidBranch(_ value: String) -> Bool {
        guard !value.isEmpty,
              matches(value, pattern: #"^[A-Za-z0-9._/-]+$"#),
              !value.hasPrefix("-"),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              !value.hasSuffix(".lock"),
              !value.contains(".."),
              !value.contains("//"),
              !value.contains("@{") else {
            return false
        }

        return true
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
