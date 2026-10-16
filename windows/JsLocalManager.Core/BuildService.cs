using System.Text.Json;

namespace AdsWorkJs.Core;

public sealed class BuildService(ICommandRunner? runner = null)
{
    private readonly ICommandRunner commands = runner ?? new ProcessRunner();

    public async Task<BuildResult> BuildAsync(string projectPath, IProgress<OperationEvent>? progress = null,
        CancellationToken token = default)
    {
        progress?.Report(new("检查本地项目", "检查目录、Git 当前分支和 buildLb 脚本…"));
        if (!Path.IsPathFullyQualified(projectPath) || !Directory.Exists(projectPath))
            throw new UserVisibleException("本地项目目录不存在或不是绝对路径。");
        var project = Path.GetFullPath(projectPath);
        if ((File.GetAttributes(project) & FileAttributes.ReparsePoint) != 0)
            throw new UserVisibleException("项目根目录不能是符号链接或重解析点。");
        using var package = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(project, "package.json"), token));
        if (!package.RootElement.TryGetProperty("scripts", out var scripts) ||
            !scripts.TryGetProperty("buildLb", out var buildScript) || buildScript.ValueKind != JsonValueKind.String)
            throw new UserVisibleException("package.json 中没有 buildLb 脚本。");
        var lockPath = Path.Combine(project, ".ads-work-build.lock");
        FileStream buildLock;
        try { buildLock = new FileStream(lockPath, FileMode.CreateNew, FileAccess.Write, FileShare.None); }
        catch (IOException ex)
        {
            throw new UserVisibleException("已有构建锁。请确认没有其他打包进程；若上次异常退出，再删除项目内 .ads-work-build.lock。", ex);
        }
        try
        {
            var root = await GitAsync(project, ["rev-parse", "--show-toplevel"], token);
            // Git prints '/' on Windows; GetFullPath normalizes it for comparison.
            if (!DataLocation.SamePath(root, project)) throw new UserVisibleException("请选择 Git 仓库根目录。");
            var branch = await GitAsync(project, ["branch", "--show-current"], token);
            if (string.IsNullOrWhiteSpace(branch)) throw new UserVisibleException("当前处于 detached HEAD，请先切换到本地分支。");
            var commit = await GitAsync(project, ["rev-parse", "HEAD"], token);
            progress?.Report(new("检查本地项目", "当前分支：" + branch + " · " + commit[..Math.Min(8, commit.Length)] + "，包含未提交修改。", true));
            var build = Path.Combine(project, "build");
            Directory.CreateDirectory(build);
            if ((File.GetAttributes(build) & FileAttributes.ReparsePoint) != 0)
                throw new UserVisibleException("build 目录不能是符号链接或重解析点。");
            var stash = Path.Combine(build, ".ads-work-previous-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stash);
            try
            {
                foreach (var old in Artifacts(build))
                    File.Move(old, Path.Combine(stash, Path.GetFileName(old)));
                progress?.Report(new("打包当前分支", "执行 npm run buildLb；旧主 JS 已暂存，失败时恢复。"));
                var executable = OperatingSystem.IsWindows()
                    ? Path.Combine(Environment.SystemDirectory, "cmd.exe") : "npm";
                string[] arguments = OperatingSystem.IsWindows()
                    ? ["/d", "/s", "/c", "npm.cmd run buildLb"] : ["run", "buildLb"];
                _ = await commands.RunAsync(executable, arguments, project, TimeSpan.FromMinutes(15), progress, token);
                progress?.Report(new("校验产物", "识别本次唯一主 JS，校验语法与文件摘要…"));
                if (await GitAsync(project, ["branch", "--show-current"], token) != branch ||
                    await GitAsync(project, ["rev-parse", "HEAD"], token) != commit)
                    throw new UserVisibleException("打包期间分支或提交发生变化，已停止，请重新打包。");
                var candidates = Artifacts(build);
                if (candidates.Length != 1)
                    throw new UserVisibleException("本次应生成唯一的 *_main.min.js（或 main.min.js），实际找到 " + candidates.Length + " 个；未安装。");
                var digest = await FileInspector.InspectAsync(candidates[0], token: token);
                token.ThrowIfCancellationRequested();
                Restore(stash, build, Path.GetFileName(candidates[0]));
                return new BuildResult(branch, candidates[0], digest);
            }
            catch (Exception original)
            {
                try { Restore(stash, build); }
                catch (Exception recovery)
                {
                    throw new UserVisibleException("打包未完成；恢复旧产物也失败，请保留暂存目录：" + stash +
                        "\n原错误：" + original.Message + "\n恢复错误：" + recovery.Message, original);
                }
                throw;
            }
        }
        finally
        {
            await buildLock.DisposeAsync();
            File.Delete(lockPath);
        }
    }

    private Task<string> GitAsync(string project, string[] arguments, CancellationToken token)
        => commands.RunAsync("git", arguments, project, TimeSpan.FromSeconds(30), null, token);

    private static string[] Artifacts(string directory)
    {
        var values = Directory.EnumerateFileSystemEntries(directory)
            .Where(path => Path.GetFileName(path).Equals("main.min.js", StringComparison.OrdinalIgnoreCase) ||
                           Path.GetFileName(path).EndsWith("_main.min.js", StringComparison.OrdinalIgnoreCase)).ToArray();
        foreach (var path in values) FileInspector.RequireRegularFile(path);
        return values;
    }

    private static void Restore(string stash, string build, string? excluding = null)
    {
        if (!Directory.Exists(stash)) return;
        foreach (var old in Directory.GetFiles(stash))
        {
            if (Path.GetFileName(old) == excluding) continue;
            File.Move(old, Path.Combine(build, Path.GetFileName(old)), overwrite: true);
        }
        Directory.Delete(stash, recursive: true);
    }
}
