using System.Text.RegularExpressions;

namespace AdsWorkJs.Core;

public static partial class LogRedactor
{
    public static string Redact(string text)
    {
        var result = Ansi().Replace(text, "");
        result = Url().Replace(result, "[下载/远程地址]");
        result = WindowsPath().Replace(result, "[本地路径]");
        result = UnixPath().Replace(result, "[本地路径]");
        return result.Length > 8000 ? result[..8000] + "（已截断）" : result;
    }

    [GeneratedRegex(@"\x1B\[[0-?]*[ -/]*[@-~]")] private static partial Regex Ansi();
    [GeneratedRegex(@"(?:https?|ssh|git)://[^\s'""<>]+", RegexOptions.IgnoreCase)] private static partial Regex Url();
    [GeneratedRegex(@"[A-Z]:\\[^\r\n'""<>]+", RegexOptions.IgnoreCase)] private static partial Regex WindowsPath();
    [GeneratedRegex(@"/(?:Users|home|private|tmp|var)/[^\s'""<>]+")] private static partial Regex UnixPath();
}
