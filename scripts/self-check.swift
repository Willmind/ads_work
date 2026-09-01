import Darwin
import Foundation

@main
enum SelfCheck {
    static func main() {
        var failures: [String] = []

        check(ConfigValidator.isValidBranch("develop"), "应接受 develop", failures: &failures)
        check(
            ConfigValidator.isValidBranch("feature/ADS-123_login-page"),
            "应接受常见 feature 分支",
            failures: &failures
        )
        check(!ConfigValidator.isValidBranch("-force"), "应拒绝 - 开头的分支", failures: &failures)
        check(!ConfigValidator.isValidBranch("feature/../../main"), "应拒绝路径穿越", failures: &failures)
        check(!ConfigValidator.isValidBranch("main; reboot"), "应拒绝命令字符", failures: &failures)
        check(!ConfigValidator.isValidBranch("feature//login"), "应拒绝双斜杠", failures: &failures)

        let output = """
        ignored output
        __MWD_BRANCHES_BEGIN__\r
        main\r
        feature/login\r
        main\r
        invalid branch\r
        __MWD_BRANCHES_END__\r
        ignored output
        """
        check(
            OutputParser.branches(from: output) == ["feature/login", "main"],
            "应解析、过滤并去重远程分支",
            failures: &failures
        )

        let coloredOutput = "\u{001B}\u{005B}32m完成\u{001B}\u{005B}0m\r\n__MWD_DEPLOY_OK__\r\n"
        check(
            OutputParser.cleanForDisplay(coloredOutput) == "完成\n",
            "应移除 ANSI 转义和协议标记",
            failures: &failures
        )

        if failures.isEmpty {
            print("Self-check passed")
            return
        }

        for failure in failures {
            fputs("Self-check failed: \(failure)\n", stderr)
        }
        exit(1)
    }

    private static func check(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition {
            failures.append(message)
        }
    }
}
