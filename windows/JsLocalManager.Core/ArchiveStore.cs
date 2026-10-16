using System.Text.Json;

namespace AdsWorkJs.Core;

public sealed class ArchiveStore(string root)
{
    public string Root { get; } = Path.GetFullPath(root);
    private string IndexPath => Path.Combine(Root, "index.json");

    public ArchiveIndex Load()
    {
        if (!File.Exists(IndexPath)) return new ArchiveIndex();
        FileInspector.RequireRegularFile(IndexPath);
        var index = JsonSerializer.Deserialize<ArchiveIndex>(File.ReadAllText(IndexPath))
            ?? throw new UserVisibleException("本地 JS 索引无效，未修改历史记录。");
        if (index.FormatVersion != 1) throw new UserVisibleException("本地 JS 索引格式不兼容，未修改历史记录。");
        return index;
    }

    public string FileFor(JsArtifact artifact) => Path.Combine(Root, "files", artifact.Id.ToString("N"), "main.min.js");

    public Task<JsArtifact> ArchiveAsync(string source, ArtifactSource sourceKind, string note,
        string? branch = null, string? fileName = null, string? expectedMd5 = null, CancellationToken token = default)
        => WithLockAsync(async () =>
        {
            var digest = await FileInspector.InspectAsync(source, token: token);
            if (expectedMd5 is not null && !digest.Md5.Equals(expectedMd5, StringComparison.OrdinalIgnoreCase))
                throw new UserVisibleException("MD5 不一致，未保存或安装这个 JS。");
            var name = fileName ?? Path.GetFileName(source);
            var artifact = new JsArtifact(Guid.NewGuid(), name, FileInspector.VersionIn(name), Limit(note, 4000),
                sourceKind, DateTimeOffset.Now, branch, digest.Sha256, digest.Md5, digest.Size);
            var destination = FileFor(artifact);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            try
            {
                File.Copy(source, destination);
                var archived = await FileInspector.InspectAsync(destination, checkSyntax: false, token);
                if (archived.Sha256 != artifact.Sha256) throw new UserVisibleException("归档复制校验失败，未保存记录。");
                token.ThrowIfCancellationRequested();
                var index = Load();
                index.Artifacts.Insert(0, artifact);
                Save(index);
                return artifact;
            }
            catch
            {
                Directory.Delete(Path.GetDirectoryName(destination)!, recursive: true);
                throw;
            }
        });

    public Task UpdateAsync(Guid id, string version, string note) => WithLockAsync(() =>
    {
        var index = Load();
        var position = index.Artifacts.FindIndex(item => item.Id == id);
        if (position < 0) throw new UserVisibleException("选中的 JS 不存在，请刷新列表。");
        index.Artifacts[position] = index.Artifacts[position] with
        {
            Version = string.IsNullOrWhiteSpace(version) ? "未标记版本" : Limit(version.Trim(), 100),
            Note = Limit(note, 4000)
        };
        Save(index);
        return Task.FromResult(true);
    });

    public Task<InstallationResult> InstallAsync(Guid id, string libraryPath,
        IProgress<OperationEvent>? progress = null, CancellationToken token = default)
        => WithLockAsync(async () =>
        {
            var index = Load();
            var artifact = index.Artifacts.FirstOrDefault(item => item.Id == id)
                ?? throw new UserVisibleException("选中的 JS 不存在，请刷新列表。");
            progress?.Report(new("校验产物", "检查历史 JS 的内容与 SHA-256…"));
            var source = FileFor(artifact);
            var info = await FileInspector.InspectAsync(source, token: token);
            if (info.Sha256 != artifact.Sha256) throw new UserVisibleException("历史 JS 文件已被修改，校验失败，未安装。");
            return await ReplaceAsync(source, artifact.Sha256, FileInspector.Destination(libraryPath),
                "安装 " + artifact.Version, index, progress, token);
        });

    public Task<InstallationResult> RestoreAsync(Guid id, string libraryPath,
        IProgress<OperationEvent>? progress = null, CancellationToken token = default)
        => WithLockAsync(async () =>
        {
            var index = Load();
            var backup = index.Backups.FirstOrDefault(item => item.Id == id)
                ?? throw new UserVisibleException("备份记录不存在，请刷新列表。");
            var destination = FileInspector.Destination(libraryPath);
            if (!DataLocation.SamePath(backup.TargetPath, destination))
                throw new UserVisibleException("该备份属于其他目标目录，请选择对应的 lib。");
            progress?.Report(new("校验备份", "检查备份内容与 SHA-256…"));
            var info = await FileInspector.InspectAsync(backup.FilePath, token: token);
            if (info.Sha256 != backup.Sha256) throw new UserVisibleException("备份已被修改，校验失败，未恢复。");
            return await ReplaceAsync(backup.FilePath, backup.Sha256, destination, "恢复备份",
                index, progress, token);
        });

    private async Task<InstallationResult> ReplaceAsync(string source, string checksum, string destination,
        string label, ArchiveIndex index, IProgress<OperationEvent>? progress, CancellationToken token)
    {
        var directory = Path.GetDirectoryName(destination)!;
        var temporary = Path.Combine(directory, ".main-" + Guid.NewGuid().ToString("N") + ".tmp");
        string? backupPath = null;
        try
        {
            token.ThrowIfCancellationRequested();
            File.Copy(source, temporary);
            var copied = await FileInspector.InspectAsync(temporary, checkSyntax: false, token);
            if (copied.Sha256 != checksum) throw new UserVisibleException("复制校验失败，未替换目标。");
            FileInspector.ValidateTarget(destination);
            string? previousHash = null;
            if (File.Exists(destination))
            {
                progress?.Report(new("备份原文件", "保存当前 main.min.js 的独立备份…"));
                backupPath = destination + ".backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8];
                File.Copy(destination, backupPath);
                var backup = await FileInspector.InspectAsync(backupPath, checkSyntax: false, token);
                var current = await FileInspector.InspectAsync(destination, checkSyntax: false, token);
                if (backup.Sha256 != current.Sha256) throw new UserVisibleException("原文件备份校验失败，未安装。");
                previousHash = current.Sha256;
                index.Backups.Insert(0, new BackupRecord(Guid.NewGuid(), backupPath, destination,
                    DateTimeOffset.Now, backup.Sha256, label));
                // Persist the recoverable backup before committing the replacement.
                Save(index);
            }
            token.ThrowIfCancellationRequested();
            progress?.Report(new("替换主文件", "更新 main.min.js…"));
            FileInspector.ValidateTarget(destination);
            if (previousHash is not null)
            {
                var current = await FileInspector.InspectAsync(destination, checkSyntax: false, token);
                if (current.Sha256 != previousHash) throw new UserVisibleException("目标文件在安装期间发生变化，请重新操作。");
                token.ThrowIfCancellationRequested();
                File.Replace(temporary, destination, destinationBackupFileName: null);
            }
            else
            {
                // Do not overwrite an unexpected file created after preflight.
                File.Move(temporary, destination);
            }
            return new InstallationResult(destination, backupPath, label);
        }
        catch (IOException ex)
        {
            throw new UserVisibleException("安装或恢复失败，原文件未被强制覆盖。请完全退出 AdsPower，检查目标目录权限或文件占用后重试。", ex);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private async Task<T> WithLockAsync<T>(Func<Task<T>> action)
    {
        Directory.CreateDirectory(Root);
        FileStream gate;
        try { gate = new FileStream(Path.Combine(Root, ".library.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException ex) { throw new UserVisibleException("另一个窗口正在操作 JS 库，请稍后重试。", ex); }
        await using (gate) { return await action(); }
    }

    private void Save(ArchiveIndex index) => AtomicJson.Write(IndexPath, index);
    private static string Limit(string value, int length) => value.Length > length ? value[..length] : value;
}
