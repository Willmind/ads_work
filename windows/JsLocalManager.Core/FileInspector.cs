using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Acornima;

namespace AdsWorkJs.Core;

public static partial class FileInspector
{
    public const long MaximumSize = 100L * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static async Task<FileDigest> InspectAsync(string path, bool checkSyntax = true, CancellationToken token = default)
    {
        RequireRegularFile(path);
        var size = new FileInfo(path).Length;
        if (size > MaximumSize || (checkSyntax && size == 0))
            throw new UserVisibleException("JS 文件不能为空，且不能超过 100 MB。");
        var bytes = await File.ReadAllBytesAsync(path, token);
        if (bytes.LongLength != size) throw new UserVisibleException("读取期间文件发生变化，请重试。");
        if (checkSyntax)
        {
            string source;
            try { source = StrictUtf8.GetString(bytes); }
            catch (DecoderFallbackException ex) { throw new UserVisibleException("文件不是有效的 UTF-8 JavaScript。", ex); }
            source = source.TrimStart('\uFEFF');
            var start = source.TrimStart();
            if (start.Length == 0 || start[0] == '<' || source.Contains('\0'))
                throw new UserVisibleException("内容是网页、空白或无效文件，不能安装为 JS。");
            if (source.StartsWith("#!", StringComparison.Ordinal))
            {
                var newline = source.IndexOf('\n');
                source = newline >= 0 ? source[newline..] : "";
            }
            token.ThrowIfCancellationRequested();
            try
            {
                // Parse CommonJS syntax only. Do not execute imported or downloaded code.
                _ = new Parser().ParseScript("function __ads_work_bundle__(){\n" + source + "\n}");
            }
            catch (ParseErrorException ex)
            {
                throw new UserVisibleException("JavaScript 语法校验失败，请选择完整的主 JS 文件。", ex);
            }
        }
        token.ThrowIfCancellationRequested();
        return new FileDigest(
            Convert.ToHexStringLower(SHA256.HashData(bytes)),
            Convert.ToHexStringLower(MD5.HashData(bytes)), size);
    }

    public static void RequireRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new UserVisibleException("文件必须是普通文件，不能是目录、符号链接或重解析点。");
    }

    public static string Destination(string directory)
    {
        if (!Path.IsPathFullyQualified(directory) || !Directory.Exists(directory))
            throw new UserVisibleException("目标 lib 目录不存在或不是绝对路径，请重新选择。");
        var full = Path.GetFullPath(directory);
        if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
            throw new UserVisibleException("目标 lib 不能是符号链接或重解析点。");
        var target = Path.Combine(full, "main.min.js");
        ValidateTarget(target);
        return target;
    }

    public static void ValidateTarget(string path)
    {
        // GetAttributes also detects dangling symlinks; File.Exists alone does not.
        try { RequireRegularFile(path); }
        catch (FileNotFoundException) { }
    }

    public static string VersionIn(string fileName)
    {
        var match = VersionPattern().Match(fileName);
        return match.Success ? match.Value : "未标记版本";
    }

    [GeneratedRegex(@"(?i)^v?\d+(?:\.\d+){1,6}(?=_|[.-]main|$)")]
    private static partial Regex VersionPattern();
}
