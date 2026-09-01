import Foundation

enum OutputParser {
    private static let ansiPattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))"

    static func cleanForDisplay(_ text: String) -> String {
        let withoutANSI = text.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )

        return withoutANSI
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("__MWD_") }
            .joined(separator: "\n")
    }

    static func branches(from output: String) -> [String] {
        guard let start = output.range(of: "__MWD_BRANCHES_BEGIN__"),
              let end = output.range(
                of: "__MWD_BRANCHES_END__",
                range: start.upperBound..<output.endIndex
              ) else {
            return []
        }

        return output[start.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(ConfigValidator.isValidBranch)
            .reduce(into: [String]()) { result, branch in
                if !result.contains(branch) {
                    result.append(branch)
                }
            }
            .sorted()
    }
}
