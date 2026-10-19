using System.Text.Json;

namespace AdsWorkJs.Core;

public sealed record BuildDirectoryFile(string Name, long Size, DateTimeOffset ModifiedAt);
public sealed record BuildDirectorySnapshot(string Path, bool Exists, int EntryCount, BuildDirectoryFile[] Files);

public sealed class BuildDirectoryLock : IDisposable
{
    private readonly string path;
    private readonly FileStream stream;

    public BuildDirectoryLock(string project)
    {
        path = System.IO.Path.Combine(project, ".ads-work-build.lock");
        try { stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); }
        catch (IOException error) { throw new UserVisibleException("已有构建锁。请确认没有其他打包或清空进程；若上次异常退出，再删除项目内 .ads-work-build.lock。", error); }
    }

    public void Dispose() { stream.Dispose(); File.Delete(path); }
}

public static class BuildDirectory
{
    public static string Project(string path)
    {
        if (!System.IO.Path.IsPathFullyQualified(path) || !Directory.Exists(path))
            throw new UserVisibleException("本地项目目录不存在或不是绝对路径。");
        var project = System.IO.Path.GetFullPath(path);
        RequireDirectory(project);
        project = PhysicalPath(project);
        using var package = JsonDocument.Parse(File.ReadAllText(System.IO.Path.Combine(project, "package.json")));
        if (package.RootElement.ValueKind != JsonValueKind.Object || !package.RootElement.TryGetProperty("scripts", out var scripts) || scripts.ValueKind != JsonValueKind.Object ||
            !scripts.TryGetProperty("buildLb", out var script) || script.ValueKind != JsonValueKind.String)
            throw new UserVisibleException("package.json 中没有 buildLb 脚本。");
        return project;
    }

    public static BuildDirectorySnapshot Read(string path)
    {
        var build = System.IO.Path.Combine(Project(path), "build");
        if (!Exists(build)) return new(build, false, 0, []);
        RequireDirectory(build);
        var entries = Walk(build, strict: false);
        var files = entries.Where(item => !item.Directory && System.IO.Path.GetExtension(item.Path).Equals(".js", StringComparison.OrdinalIgnoreCase))
            .Select(item => new BuildDirectoryFile(System.IO.Path.GetRelativePath(build, item.Path).Replace('\\', '/'),
                new FileInfo(item.Path).Length, File.GetLastWriteTimeUtc(item.Path)))
            .OrderByDescending(file => file.ModifiedAt).ThenBy(file => file.Name, StringComparer.Ordinal).ToArray();
        return new(build, true, entries.Count, files);
    }

    public static string FileIn(string project, string name)
    {
        var parts = name.Split('/');
        if (parts.Any(part => string.IsNullOrEmpty(part) || part is "." or ".." ||
                part.StartsWith(".ads-work-previous-", StringComparison.Ordinal) || part.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0) ||
            name.Contains('\\') || name.Contains(':') || !System.IO.Path.GetExtension(name).Equals(".js", StringComparison.OrdinalIgnoreCase))
            throw new UserVisibleException("请选择 build 列表中的 JS 文件。");
        var source = System.IO.Path.Combine(project, "build");
        RequireDirectory(source);
        foreach (var part in parts[..^1]) { source = System.IO.Path.Combine(source, part); RequireDirectory(source); }
        source = System.IO.Path.Combine(source, parts[^1]);
        var attributes = File.GetAttributes(source);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
            throw new UserVisibleException("JS 文件已变化或不是普通文件，请刷新后重试。");
        return source;
    }

    public static int Clear(string path, IEnumerable<string> protectedPaths, CancellationToken token = default)
    {
        var project = Project(path);
        using var buildLock = new BuildDirectoryLock(project);
        var build = System.IO.Path.Combine(project, "build");
        if (!Exists(build)) return 0;
        RequireDirectory(build);
        foreach (var protectedPath in protectedPaths.Where(System.IO.Path.IsPathFullyQualified))
        {
            var value = PhysicalPath(protectedPath);
            if (DataLocation.SamePath(value, build) || value.StartsWith(build + System.IO.Path.DirectorySeparatorChar, DataLocation.PathComparison))
                throw new UserVisibleException("build 内包含已配置的安装目录或 JS 历史库，已拒绝清空。");
        }
        var entries = Walk(build, strict: true);
        var count = 0;
        foreach (var item in entries.AsEnumerable().Reverse())
        {
            token.ThrowIfCancellationRequested();
            RequireDirectory(build);
            var parent = System.IO.Path.GetDirectoryName(item.Path)!;
            while (!DataLocation.SamePath(parent, build))
            {
                RequireDirectory(parent);
                parent = System.IO.Path.GetDirectoryName(parent)!;
            }
            if (!Exists(item.Path)) continue;
            var attributes = File.GetAttributes(item.Path);
            if ((attributes & FileAttributes.ReparsePoint) != 0 || attributes.HasFlag(FileAttributes.Directory) != item.Directory)
                throw new UserVisibleException("build 内容在清空时发生变化，已停止；部分文件可能已删除。");
            if (item.Directory) Directory.Delete(item.Path, recursive: false); else File.Delete(item.Path);
            count++;
        }
        return count;
    }

    private static bool Exists(string path)
    {
        try { _ = File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    internal static string PhysicalPath(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        var root = System.IO.Path.GetPathRoot(full)!;
        var resolved = root;
        foreach (var part in full[root.Length..].Split([System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            resolved = System.IO.Path.Combine(resolved, part);
            if (!Exists(resolved)) continue;
            var attributes = File.GetAttributes(resolved);
            if (!attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
            FileSystemInfo info = attributes.HasFlag(FileAttributes.Directory) ? new DirectoryInfo(resolved) : new FileInfo(resolved);
            resolved = info.ResolveLinkTarget(returnFinalTarget: true)?.FullName
                ?? throw new UserVisibleException("无法解析目录链接，已停止操作。");
        }
        return System.IO.Path.GetFullPath(resolved);
    }

    private static void RequireDirectory(string path)
    {
        var attributes = File.GetAttributes(path);
        if (!attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new UserVisibleException("项目、build 及其子目录必须是普通目录，不能是符号链接或重解析点。");
    }

    private static List<(string Path, bool Directory)> Walk(string root, bool strict)
    {
        var entries = new List<(string Path, bool Directory)>();
        var pending = new Stack<(string Path, int Depth)>(); pending.Push((root, 0));
        while (pending.TryPop(out var current))
        {
            if (current.Depth >= 64 || entries.Count >= 20000) throw new UserVisibleException("build 内容过多或层级过深，已停止读取或清空。");
            RequireDirectory(current.Path);
            foreach (var path in Directory.EnumerateFileSystemEntries(current.Path))
            {
                if (entries.Count >= 20000) throw new UserVisibleException("build 内容过多，已停止读取或清空。");
                FileAttributes attributes;
                try { attributes = File.GetAttributes(path); }
                catch (FileNotFoundException) when (!strict) { continue; }
                var recovery = System.IO.Path.GetFileName(path).StartsWith(".ads-work-previous-", StringComparison.Ordinal);
                if (recovery || attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    if (strict) throw new UserVisibleException("build 含符号链接、重解析点或旧产物恢复目录，未开始清空，请先检查。");
                    continue;
                }
                var directory = attributes.HasFlag(FileAttributes.Directory);
                entries.Add((path, directory));
                if (directory) pending.Push((path, current.Depth + 1));
            }
        }
        return entries;
    }
}
