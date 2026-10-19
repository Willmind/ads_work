using AdsWorkJs.Core;
using System.Diagnostics;
using System.Text.Json;

namespace AdsWorkJs;

internal sealed class DesktopController
{
    private readonly Form owner;
    private readonly Action<string, object> publish;
    private readonly ArchiveStore archive;
    private readonly SettingsStore settingsStore;
    private readonly DownloadClient downloader = new();
    private AppSettings settings;
    private CancellationTokenSource? operation;
    private readonly List<string> logs = [];
    private object? status;
    private bool stopping;
    private bool confirmingClear;
    private bool copyingFile;
    private DateTime lastLogPublish;
    public bool Busy => operation is not null || confirmingClear;

    internal DesktopController(Form owner, string root, Action<string, object> publish)
    {
        this.owner = owner; this.publish = publish;
        archive = new ArchiveStore(root); settingsStore = new SettingsStore(root);
        settings = settingsStore.Load();
        _ = archive.Load();
    }

    internal object Snapshot(Guid? selectedId = null)
    {
        var index = archive.Load();
        var target = Path.IsPathFullyQualified(settings.LibraryPath) ? Path.Combine(settings.LibraryPath, "main.min.js") : null;
        return new
        {
            settings, records = index.Artifacts,
            backups = index.Backups.Where(backup => target is not null && DataLocation.SamePath(backup.TargetPath, target)),
            busy = Busy, stopping, logs = string.Join('\n', logs), operation = status, selectedId
        };
    }

    internal async Task<object> HandleAsync(UiRequest request)
    {
        var args = request.Args;
        if (request.Action == "cancel") { Cancel(); return new { snapshot = Snapshot() }; }
        if (request.Action == "state") return new { snapshot = Snapshot() };
        if (request.Action == "buildFiles")
        {
            var directory = await Task.Run(() => BuildDirectory.Read(UiProtocol.Text(args, "projectPath")));
            return new { buildDirectory = directory };
        }
        if (request.Action == "copyLog")
        {
            if (logs.Count > 0) Clipboard.SetText(string.Join('\n', logs));
            return new { message = "日志已复制" };
        }
        if (Busy) throw new UserVisibleException("当前操作尚未结束，请稍后重试。");
        if (request.Action == "copyBuildFile") return await CopyBuildFileAsync(request);
        ReadSettings(args);
        switch (request.Action)
        {
            case "clearBuild":
                var buildPath = Path.Combine(BuildDirectory.Project(settings.ProjectPath), "build");
                confirmingClear = true;
                bool confirmed;
                try
                {
                    confirmed = MessageBox.Show(owner, "将删除以下目录内的所有文件和子目录，保留 build 目录本身：\n\n" + buildPath +
                        "\n\n删除不可撤销；已保存的 JS 历史和 AdsPower 安装文件不受影响。", "清空 build 文件夹？",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
                }
                finally { confirmingClear = false; }
                if (!confirmed) return new { snapshot = Snapshot(), message = "已取消清空，build 文件未改动" };
                return await RunAsync(request);
            case "saveSettings": return new { snapshot = Snapshot(), message = "路径已保存到本机" };
            case "chooseProject": case "chooseLibrary":
                ChooseDirectory(request.Action == "chooseProject");
                return new { snapshot = Snapshot() };
            case "openArchive":
                var selected = archive.Load().Artifacts.FirstOrDefault(record => record.Id == UiProtocol.Id(args))
                    ?? throw new UserVisibleException("所选记录不存在。");
                var path = Path.GetDirectoryName(archive.FileFor(selected))!;
                if (!Directory.Exists(path)) throw new UserVisibleException("归档文件夹不存在。");
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                return new { message = "已打开归档文件夹" };
            case "updateMetadata":
                await archive.UpdateAsync(UiProtocol.Id(args), UiProtocol.Text(args, "version", 100), UiProtocol.Text(args, "note"));
                return new { snapshot = Snapshot(), message = "版本和备注已保存" };
            default: return await RunAsync(request);
        }
    }

    private async Task<object> CopyBuildFileAsync(UiRequest request)
    {
        var project = UiProtocol.Text(request.Args, "projectPath");
        var name = UiProtocol.Text(request.Args, "fileName");
        var cache = new BuildFileCopies(Path.Combine(archive.Root, "copied-js"));
        using var cancellation = new CancellationTokenSource();
        operation = cancellation; copyingFile = true; stopping = false;
        status = new { state = "running", stage = "复制文件", message = "正在准备 JS 文件副本…" };
        publish("state", Snapshot());
        try
        {
            var file = await Task.Run(() => cache.CreateAsync(project, name, cancellation.Token), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            var data = new DataObject(); data.SetData(DataFormats.FileDrop, true, new[] { file });
            using var effect = new MemoryStream(BitConverter.GetBytes((int)DragDropEffects.Copy));
            data.SetData("Preferred DropEffect", effect);
            Clipboard.SetDataObject(data, copy: true);
            try { cache.Prune([file]); }
            catch (Exception) { Debug.WriteLine("复制文件成功，但旧副本缓存未能清理；下次复制时将重试。"); }
            status = new { state = "success", stage = "操作完成", message = "JS 文件已复制，可直接粘贴到文件夹" };
            return new { message = "JS 文件已复制，可直接粘贴到文件夹", copiedFile = name };
        }
        catch (OperationCanceledException error)
        {
            status = new { state = "cancelled", stage = "已停止", message = "复制已停止，剪贴板未更新。" };
            throw new UserVisibleException("复制已停止，剪贴板未更新。", error);
        }
        catch (Exception error)
        {
            status = new { state = "failure", stage = "复制未完成", message = LogRedactor.Redact(error.Message) };
            throw;
        }
        finally { operation = null; copyingFile = false; stopping = false; publish("state", Snapshot()); }
    }

    private async Task<object> RunAsync(UiRequest request)
    {
        string? importPath = null;
        if (request.Action == "import")
        {
            using var dialog = new OpenFileDialog { Title = "选择主 JS 文件", Filter = "JavaScript (*.js)|*.js|所有文件 (*.*)|*.*", CheckFileExists = true };
            if (dialog.ShowDialog(owner) != DialogResult.OK) return new { snapshot = Snapshot() };
            importPath = dialog.FileName;
        }
        using var cancellation = new CancellationTokenSource();
        operation = cancellation; stopping = false; logs.Clear();
        Guid? selectedId = null;
        var progress = new Progress<OperationEvent>(value =>
        {
            if (operation == cancellation) UpdateProgress(value);
        });
        UpdateProgress(new("检查本地文件", "正在准备操作…"));
        try
        {
            var args = request.Args;
            var token = cancellation.Token;
            string message;
            switch (request.Action)
            {
                case "clearBuild":
                    var count = await Task.Run(() => BuildDirectory.Clear(settings.ProjectPath, [settings.LibraryPath, archive.Root], token), token);
                    message = $"build 已清空，共删除 {count} 项；本地 JS 历史和安装文件保留。";
                    break;
                case "buildSave": case "buildInstall":
                    if (request.Action == "buildInstall") _ = FileInspector.Destination(settings.LibraryPath);
                    var built = await Task.Run(() => new BuildService().BuildAsync(settings.ProjectPath, progress, token), token);
                    var artifact = await Task.Run(() => archive.ArchiveAsync(built.ArtifactPath, ArtifactSource.Build,
                        UiProtocol.Text(args, "note"), built.Branch, token: token), token);
                    selectedId = artifact.Id;
                    message = "打包成功，JS 已保存到独立历史。";
                    if (request.Action == "buildInstall")
                        message = Installed(await Task.Run(() => archive.InstallAsync(artifact.Id, settings.LibraryPath, progress, token), token));
                    break;
                case "download":
                    var spec = DownloadSpec.Parse(UiProtocol.Text(args, "url", 8000), UiProtocol.Text(args, "md5", 32));
                    var temporary = await Task.Run(() => downloader.DownloadAsync(spec, progress, token), token);
                    try
                    {
                        var record = await Task.Run(() => archive.ArchiveAsync(temporary, ArtifactSource.Download,
                            UiProtocol.Text(args, "note"), fileName: spec.FileName, expectedMd5: spec.ExpectedMd5, token: token), token);
                        selectedId = record.Id;
                    }
                    finally { File.Delete(temporary); }
                    message = "下载和校验完成，已保存到本地历史。选中后可安装。";
                    break;
                case "import":
                    var imported = await Task.Run(() => archive.ArchiveAsync(importPath!, ArtifactSource.File, UiProtocol.Text(args, "note"), token: token), token);
                    selectedId = imported.Id; message = "文件校验通过，已保存到本地历史。";
                    break;
                case "install":
                    selectedId = UiProtocol.Id(args);
                    message = Installed(await Task.Run(() => archive.InstallAsync(selectedId.Value, settings.LibraryPath, progress, token), token));
                    break;
                case "restore":
                    message = Installed(await Task.Run(() => archive.RestoreAsync(UiProtocol.Id(args), settings.LibraryPath, progress, token), token));
                    break;
                default: throw new UserVisibleException("不支持的本地操作。");
            }
            status = new { state = "success", stage = "操作完成", message };
            AddLog(message);
        }
        catch (OperationCanceledException)
        {
            status = new { state = "cancelled", stage = "已停止", message = request.Action == "clearBuild" ? "清空已停止；已经删除的 build 内容不会恢复，请核对实时列表。" : "操作已停止，已归档的记录和备份仍保留在本机。" };
            AddLog("操作已停止。");
        }
        catch (Exception error)
        {
            status = new { state = "failure", stage = "操作失败", message = request.Action == "clearBuild" ? "清空未完成（部分内容可能已删除）：" + error.Message : error.Message };
            AddLog(error.Message);
        }
        finally
        {
            operation = null; stopping = false;
            publish("state", Snapshot(selectedId));
        }
        return new { snapshot = Snapshot(selectedId) };
    }

    private void UpdateProgress(OperationEvent value)
    {
        if (!Busy) return;
        AddLog(value.Message);
        if (!value.IsLog) status = new { state = "running", stage = value.Stage, message = value.Message };
        if (value.IsLog && DateTime.UtcNow - lastLogPublish < TimeSpan.FromMilliseconds(100)) return;
        lastLogPublish = DateTime.UtcNow;
        publish("progress", new { busy = true, stopping, operation = status, logs = string.Join('\n', logs) });
    }

    private void AddLog(string text)
    {
        logs.Add(LogRedactor.Redact(text));
        while (logs.Count > 160 || logs.Sum(line => line.Length) > 45000) logs.RemoveAt(0);
    }

    internal void Cancel()
    {
        if (operation is null) return;
        stopping = true; operation.Cancel();
        status = new { state = "running", stage = "正在停止", message = copyingFile ? "正在停止复制文件…" : "正在结束子进程并恢复暂存的旧产物…" };
        publish("progress", new { busy = true, stopping, operation = status, logs = string.Join('\n', logs) });
    }

    private void ReadSettings(JsonElement args)
    {
        if (!args.TryGetProperty("settings", out var value)) return;
        if (value.ValueKind != JsonValueKind.Object) throw new UserVisibleException("路径配置无效。");
        settings = new AppSettings { ProjectPath = UiProtocol.Text(value, "projectPath"), LibraryPath = UiProtocol.Text(value, "libraryPath") };
        settingsStore.Save(settings);
    }

    private void ChooseDirectory(bool project)
    {
        using var dialog = new FolderBrowserDialog { Description = project ? "选择本地项目" : "选择 AdsPower lib", UseDescriptionForTitle = true, ShowNewFolderButton = false };
        var previous = project ? settings.ProjectPath : settings.LibraryPath;
        if (Directory.Exists(previous)) dialog.InitialDirectory = previous;
        if (dialog.ShowDialog(owner) != DialogResult.OK) return;
        if (project) settings.ProjectPath = dialog.SelectedPath; else settings.LibraryPath = dialog.SelectedPath;
        settingsStore.Save(settings);
    }

    internal void Dispose() => downloader.Dispose();
    private static string Installed(InstallationResult result) => "已更新 " + result.TargetPath +
        (result.BackupPath is null ? "" : "\n原文件已自动备份，可在“备份与恢复”中恢复。") + "\n重新启动 AdsPower 后验证。";
}
