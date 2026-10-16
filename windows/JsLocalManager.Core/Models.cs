namespace AdsWorkJs.Core;

public sealed class AppSettings
{
    public string ProjectPath { get; set; } = @"C:\install\mix_client";
    public string LibraryPath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "adspower_global", "cwd_global", "lib");
}

public enum ArtifactSource { Build, Download, File }

public sealed record JsArtifact(
    Guid Id, string FileName, string Version, string Note, ArtifactSource Source,
    DateTimeOffset CreatedAt, string? Branch, string Sha256, string Md5, long Size)
{
    public string SourceLabel => Source switch
    {
        ArtifactSource.Build => "本地打包",
        ArtifactSource.Download => "链接下载",
        _ => "文件导入"
    };

    public bool Matches(string query)
    {
        var text = string.Join(" ", Version, Note, FileName, Branch, SourceLabel);
        return query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .All(keyword => text.Contains(keyword, StringComparison.OrdinalIgnoreCase));
    }
}

public sealed record BackupRecord(
    Guid Id, string FilePath, string TargetPath, DateTimeOffset CreatedAt, string Sha256, string Label);

public sealed class ArchiveIndex
{
    public int FormatVersion { get; set; } = 1;
    public List<JsArtifact> Artifacts { get; set; } = [];
    public List<BackupRecord> Backups { get; set; } = [];
}

public sealed record FileDigest(string Sha256, string Md5, long Size);
public sealed record BuildResult(string Branch, string ArtifactPath, FileDigest Digest);
public sealed record InstallationResult(string TargetPath, string? BackupPath, string Label);
public sealed record OperationEvent(string Stage, string Message, bool IsLog = false);

public sealed class UserVisibleException(string message, Exception? inner = null) : Exception(message, inner);

public static class DataLocation
{
    public static string DefaultRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AdsWorkJsManager");

    public static StringComparison PathComparison => OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static bool SamePath(string left, string right) => string.Equals(
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)), PathComparison);
}
