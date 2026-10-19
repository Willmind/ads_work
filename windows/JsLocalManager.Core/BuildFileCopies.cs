namespace AdsWorkJs.Core;

public sealed class BuildFileCopies(string root)
{
    public const long Limit = 100 * 1024 * 1024;

    public async Task<string> CreateAsync(string projectPath, string name, CancellationToken token = default)
    {
        var project = BuildDirectory.Project(projectPath);
        using var buildLock = new BuildDirectoryLock(project);
        var source = BuildDirectory.FileIn(project, name);
        var build = Path.Combine(project, "build");
        var cache = BuildDirectory.PhysicalPath(root);
        if (DataLocation.SamePath(cache, build) || cache.StartsWith(build + Path.DirectorySeparatorChar, DataLocation.PathComparison))
            throw new UserVisibleException("复制缓存不能位于 build 内。");
        EnsureRoot();
        var directory = Path.Combine(root, Guid.NewGuid().ToString("D"));
        Directory.CreateDirectory(directory);
        try
        {
            var target = Path.Combine(directory, Path.GetFileName(source));
            await CopyAsync(source, target, token);
            _ = BuildDirectory.FileIn(project, name);
            return target;
        }
        catch { Directory.Delete(directory, recursive: true); throw; }
    }

    private static async Task CopyAsync(string source, string target, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var before = new FileInfo(source);
        var modified = before.LastWriteTimeUtc;
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 256 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var length = input.Length;
        if (length > Limit) throw new UserVisibleException("只能复制不超过 100 MB 的普通 JS 文件。");
        await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 256 * 1024, FileOptions.Asynchronous);
        var buffer = new byte[256 * 1024]; long size = 0;
        while (true)
        {
            var count = await input.ReadAsync(buffer, token);
            if (count == 0) break;
            size += count;
            if (size > Limit) throw new UserVisibleException("JS 文件超过 100 MB，已停止复制。");
            await output.WriteAsync(buffer.AsMemory(0, count), token);
        }
        before.Refresh();
        var attributes = File.GetAttributes(source);
        if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || !before.Exists ||
            before.LastWriteTimeUtc != modified || before.Length != length || input.Length != length || size != length)
            throw new UserVisibleException("JS 文件在复制时发生变化，未更新剪贴板，请刷新后重试。");
        token.ThrowIfCancellationRequested();
    }

    // Never remove a snapshot still referenced by the current clipboard.
    public void Prune(IEnumerable<string> preserving, DateTimeOffset? now = null)
    {
        if (!Directory.Exists(root)) return;
        EnsureRoot();
        var keep = preserving.Select(path => BuildDirectory.PhysicalPath(Path.GetDirectoryName(path)!)).ToHashSet(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        var entries = Directory.EnumerateDirectories(root).Where(path => Guid.TryParseExact(Path.GetFileName(path), "D", out _))
            .Select(path => new DirectoryInfo(path)).Where(info => !info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            .OrderByDescending(info => info.LastWriteTimeUtc).ToArray();
        for (var i = 0; i < entries.Length; i++)
        {
            var entry = entries[i];
            if ((i >= 10 || (now ?? DateTimeOffset.UtcNow) - entry.LastWriteTimeUtc > TimeSpan.FromDays(7)) &&
                !keep.Contains(BuildDirectory.PhysicalPath(entry.FullName))) entry.Delete(recursive: true);
        }
    }

    private void EnsureRoot()
    {
        Directory.CreateDirectory(root);
        if (File.GetAttributes(root).HasFlag(FileAttributes.ReparsePoint)) throw new UserVisibleException("复制缓存必须是普通目录，不能是链接或重解析点。");
    }
}
