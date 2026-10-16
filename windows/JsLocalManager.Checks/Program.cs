using AdsWorkJs.Core;
using System.Net;
using System.Text;
using System.Text.Json;

namespace AdsWorkJs.Checks;

internal static class Program
{
    private static int checks;
    private static readonly ProcessRunner Runner = new();
    private static string Root = "";

    private static async Task<int> Main(string[] args)
    {
        var temporaryRoot = OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath();
        Root = Path.Combine(temporaryRoot, "ads-work-checks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Root);
        try
        {
            if (args.Length > 0 && args[0] == "--integration")
            {
                await IntegrationChecks(args);
                Console.WriteLine($"真实产物验证通过：{checks} 项断言；安装目标全部位于临时目录。");
                return 0;
            }
            await InspectChecks();
            Console.WriteLine("PASS 语法与文件检查");
            await ArchiveChecks();
            Console.WriteLine("PASS 本地归档、校验、备份、安装与恢复");
            SettingsChecks();
            Console.WriteLine("PASS Windows 默认路径与设置持久化");
            await ProtocolChecks();
            Console.WriteLine("PASS 本地页面来源、操作白名单与消息参数检查");
            await DownloadChecks();
            Console.WriteLine("PASS 只读下载、跳转限制、MD5 与异常处理");
            await BuildChecks();
            Console.WriteLine("PASS 真实 Git/npm 打包、同名产物与失败回滚");
            await ProcessChecks();
            Console.WriteLine("PASS 进程失败、超时、取消与子进程停止");
            Console.WriteLine($"全部通过：{checks} 项断言；未接触用户项目、AdsPower 目录或后台数据。");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { Directory.Delete(Root, recursive: true); }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception("断言失败：" + message);
        checks++;
    }

    private static async Task Reject(Func<Task> action, string message)
    {
        try { await action(); }
        catch (Exception error) when (error is UserVisibleException or IOException or JsonException or OperationCanceledException)
        {
            checks++;
            return;
        }
        throw new Exception("应拒绝但接受了：" + message);
    }

    private static string Folder(string name)
    {
        var path = Path.Combine(Root, name);
        Directory.CreateDirectory(path);
        return path;
    }

    private static string Write(string name, string text)
    {
        var path = Path.Combine(Root, name);
        File.WriteAllText(path, text, new UTF8Encoding(false));
        return path;
    }

    private static async Task InspectChecks()
    {
        var sentinel = Path.Combine(Root, "must-not-execute");
        var source = Write("v2.8.9.3_main.min.js", "require('fs').writeFileSync(" + JsonSerializer.Serialize(sentinel) + ", 'bad'); throw new Error('not executed');");
        var digest = await FileInspector.InspectAsync(source);
        Check(!File.Exists(sentinel), "校验不能执行 JS");
        Check(digest.Size > 0 && digest.Sha256.Length == 64 && digest.Md5.Length == 32, "文件摘要完整");
        Check(FileInspector.VersionIn(Path.GetFileName(source)) == "v2.8.9.3", "版本识别");
        Check(FileInspector.VersionIn("main.min.js") == "未标记版本", "未知版本");
        await FileInspector.InspectAsync(Write("commonjs.js", "return module.exports = () => 1;"));
        await FileInspector.InspectAsync(Write("shebang.js", "#!/usr/bin/env node\nconst a=1;"));
        foreach (var invalid in new[] { "", "   ", "<!doctype html><html>error</html>", "const = ;", "{\"error\":\"denied\"}", "var a='\0';" })
            await Reject(() => FileInspector.InspectAsync(Write("invalid.js", invalid)), "无效 JS");
        var encoding = Path.Combine(Root, "encoding.js");
        await File.WriteAllBytesAsync(encoding, [255, 254, 253]);
        await Reject(() => FileInspector.InspectAsync(encoding), "非法 UTF8");
        if (!OperatingSystem.IsWindows())
        {
            var link = Path.Combine(Root, "linked.js");
            File.CreateSymbolicLink(link, source);
            await Reject(() => FileInspector.InspectAsync(link), "符号链接");
            var dangling = Path.Combine(Folder("dangling lib"), "main.min.js");
            File.CreateSymbolicLink(dangling, Path.Combine(Root, "missing"));
            await Reject(() => Task.FromResult(FileInspector.Destination(Path.GetDirectoryName(dangling)!)), "悬空链接目标");
        }
        await Reject(() => Task.FromResult(FileInspector.Destination("relative")), "相对目标目录");
        Check(!LogRedactor.Redact("https://host/a?token=secret C:\\Users\\X\\data").Contains("secret"), "日志隐藏 URL");
    }

    private static async Task ArchiveChecks()
    {
        var store = new ArchiveStore(Folder("archive"));
        var source = Write("v2.0.0_main.min.js", "module.exports = 'first';");
        var a = await store.ArchiveAsync(source, ArtifactSource.File, "需求 alpha");
        await File.WriteAllTextAsync(source, "module.exports = 'second';");
        var b = await store.ArchiveAsync(source, ArtifactSource.Build, "需求 beta", "feature/test");
        Check(a.Id != b.Id && a.Sha256 != b.Sha256, "同版本独立归档");
        Check(await File.ReadAllTextAsync(store.FileFor(a)) == "module.exports = 'first';", "原归档未覆盖");
        Check(b.Matches("2.0 beta feature") && !b.Matches("alpha"), "组合搜索");
        await store.UpdateAsync(b.Id, "测试版", "已更新备注");
        store = new ArchiveStore(store.Root);
        Check(store.Load().Artifacts[0].Note == "已更新备注", "编辑后重开持久化");
        var lib = Folder("install lib");
        var target = Path.Combine(lib, "main.min.js");
        await File.WriteAllTextAsync(target, "module.exports = 'original';");
        var installed = await store.InstallAsync(a.Id, lib);
        Check(await File.ReadAllTextAsync(target) == "module.exports = 'first';", "安装主文件");
        Check(installed.BackupPath is not null && await File.ReadAllTextAsync(installed.BackupPath) == "module.exports = 'original';", "自动备份原文件");
        Check(store.Load().Backups.Count == 1, "备份记录保存");
        var originalBackup = store.Load().Backups[0];
        await store.InstallAsync(b.Id, lib);
        await store.RestoreAsync(originalBackup.Id, lib);
        Check(await File.ReadAllTextAsync(target) == "module.exports = 'original';", "备份恢复");
        Check(store.Load().Backups.Count == 3, "恢复前再次备份");
        Check(!Directory.GetFiles(lib, ".main-*.tmp").Any(), "临时安装文件清理");
        await Reject(() => store.RestoreAsync(originalBackup.Id, Folder("other lib")), "备份不能恢复到其他目录");
        await File.WriteAllTextAsync(store.FileFor(a), "module.exports = 'tampered';");
        await Reject(() => store.InstallAsync(a.Id, lib), "被篡改归档拒绝安装");
        Check(await File.ReadAllTextAsync(target) == "module.exports = 'original';", "校验失败保留目标");
        await File.WriteAllTextAsync(originalBackup.FilePath, "module.exports = 'tampered backup';");
        await Reject(() => store.RestoreAsync(originalBackup.Id, lib), "篡改备份拒绝恢复");
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            await Reject(() => store.InstallAsync(b.Id, lib, token: cancelled.Token), "取消安装");
        }
        Check(await File.ReadAllTextAsync(target) == "module.exports = 'original';", "取消不替换");
        using (var gate = new FileStream(Path.Combine(store.Root, ".library.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
            await Reject(() => store.UpdateAsync(b.Id, "blocked", "blocked"), "归档锁");
        var freshLib = Folder("new lib");
        var fresh = await store.InstallAsync(b.Id, freshLib);
        Check(fresh.BackupPath is null && File.Exists(fresh.TargetPath), "无旧主文件安装");
        var indexPath = Path.Combine(store.Root, "index.json");
        await File.WriteAllTextAsync(indexPath, "broken index");
        await Reject(() => store.ArchiveAsync(source, ArtifactSource.File, ""), "索引损坏拒绝覆盖");
        Check(await File.ReadAllTextAsync(indexPath) == "broken index", "索引损坏保留原文件");
        Check(Directory.GetDirectories(Path.Combine(store.Root, "files")).Length == 2, "保存失败清除本次归档");
    }

    private static void SettingsChecks()
    {
        var store = new SettingsStore(Folder("settings"));
        var defaults = store.Load();
        Check(defaults.ProjectPath == @"C:\install\mix_client", "默认项目目录");
        Check(defaults.LibraryPath.EndsWith(Path.Combine("adspower_global", "cwd_global", "lib")), "默认漫游目录");
        if (OperatingSystem.IsWindows())
            Check(defaults.LibraryPath == Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "adspower_global", "cwd_global", "lib"), "Windows 当前用户 AppData");
        store.Save(new AppSettings { ProjectPath = @"D:\project with spaces", LibraryPath = @"E:\AdsPower\lib" });
        Check(store.Load().ProjectPath == @"D:\project with spaces" && store.Load().LibraryPath == @"E:\AdsPower\lib", "自定义路径持久化");
    }

    private static async Task ProtocolChecks()
    {
        var valid = JsonSerializer.Serialize(new { id = Guid.NewGuid().ToString(), action = "state", args = new { } });
        Check(UiProtocol.Parse(UiProtocol.Page, valid).Action == "state", "合法本地请求");
        foreach (var origin in new[] { "https://evil.test/index.html", "http://adswork.local/index.html", UiProtocol.Page + "?remote=1", UiProtocol.Page + "#other", "file:///index.html" })
            await Reject(() => Task.FromResult(UiProtocol.Parse(origin, valid)), "非信任页面");
        foreach (var action in new[] { "exec", "eval", "delete", "fetch", "openUrl" })
        {
            var json = JsonSerializer.Serialize(new { id = Guid.NewGuid().ToString(), action, args = new { command = "echo unsafe" } });
            await Reject(() => Task.FromResult(UiProtocol.Parse(UiProtocol.Page, json)), "无任意执行接口");
        }
        await Reject(() => Task.FromResult(UiProtocol.Parse(UiProtocol.Page, "{}")), "缺失请求字段");
        await Reject(() => Task.FromResult(UiProtocol.Parse(UiProtocol.Page, new string('x', 65537))), "消息长度上限");
        using var values = JsonDocument.Parse("{\"note\":123,\"id\":\"not-a-guid\"}");
        await Reject(() => Task.FromResult(UiProtocol.Text(values.RootElement, "note")), "参数类型");
        await Reject(() => Task.FromResult(UiProtocol.Id(values.RootElement)), "记录 ID");
        using var longValue = JsonDocument.Parse("{\"version\":\"123456\"}");
        await Reject(() => Task.FromResult(UiProtocol.Text(longValue.RootElement, "version", 3)), "参数长度限制");
    }

    private static async Task DownloadChecks()
    {
        var source = Write("download-payload.js", "module.exports = 'download';");
        var digest = await FileInspector.InspectAsync(source);
        var url = "https://version.adspower.net/software_dev/lib_testing/v2.0.0_main.min.js" + digest.Md5;
        var spec = DownloadSpec.Parse(url);
        Check(spec.ExpectedMd5 == digest.Md5, "MD5 尾缀识别");
        foreach (var invalid in new[] { "http://version.adspower.net/a.js", "https://evil.test/a.js", "https://u:p@version.adspower.net/a.js", "https://version.adspower.net:444/a.js", "https://version.adspower.net/a.html", url + "#fragment" })
            await Reject(() => Task.FromResult(DownloadSpec.Parse(invalid)), "非法下载链接");
        await Reject(() => Task.FromResult(DownloadSpec.Parse(url, new string('0', 32))), "MD5 表单与链接冲突");
        var requests = 0;
        using (var client = new DownloadClient(new FakeHandler((request, _) =>
        {
            Check(request.Method == HttpMethod.Get && !request.Headers.Contains("Cookie") && !request.Headers.Contains("Authorization"), "仅 GET、不带登录信息");
            requests++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("module.exports = 'download';", Encoding.UTF8, "application/javascript") });
        })))
        {
            var downloaded = await client.DownloadAsync(spec);
            try { Check((await FileInspector.InspectAsync(downloaded)).Md5 == digest.Md5 && requests == 1, "完整链接下载校验"); }
            finally { File.Delete(downloaded); }
        }
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("module.exports='wrong';") }))))
            await Reject(() => client.DownloadAsync(spec), "内容 MD5 不符");
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)))))
            await Reject(() => client.DownloadAsync(spec), "HTTP 错误");
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("<html>login</html>", Encoding.UTF8, "text/html") }))))
            await Reject(() => client.DownloadAsync(spec), "拒绝登录页");
        using (var client = new DownloadClient(new FakeHandler((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1]) };
            response.Content.Headers.ContentLength = FileInspector.MaximumSize + 1;
            return Task.FromResult(response);
        }))) await Reject(() => client.DownloadAsync(spec), "超大下载");
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(Redirect("https://evil.test/a.js")))))
            await Reject(() => client.DownloadAsync(spec), "拒绝外域跳转");
        var redirects = 0;
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(++redirects == 1
            ? Redirect("/next.js") : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("module.exports = 'download';") }))))
        {
            var downloaded = await client.DownloadAsync(spec);
            File.Delete(downloaded);
            Check(redirects == 2, "允许同域跳转");
        }
        using (var client = new DownloadClient(new FakeHandler((_, _) => Task.FromResult(Redirect("/again.js")))))
            await Reject(() => client.DownloadAsync(spec), "跳转次数上限");
        using (var cancellation = new CancellationTokenSource(80))
        using (var client = new DownloadClient(new FakeHandler(async (_, token) =>
        {
            await Task.Delay(10000, token);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }))) await Reject(() => client.DownloadAsync(spec, token: cancellation.Token), "取消下载");
    }

    private static HttpResponseMessage Redirect(string value)
    {
        var response = new HttpResponseMessage(HttpStatusCode.Found);
        response.Headers.Location = new Uri(value, UriKind.RelativeOrAbsolute);
        return response;
    }

    private static async Task IntegrationChecks(string[] args)
    {
        if (args.Length < 2) throw new ArgumentException("--integration <HTTPS JS URL> [本地主 JS 路径]");
        var spec = DownloadSpec.Parse(args[1]);
        using var downloader = new DownloadClient();
        var downloaded = await downloader.DownloadAsync(spec);
        var store = new ArchiveStore(Folder("real archive"));
        try
        {
            var downloadedRecord = await store.ArchiveAsync(downloaded, ArtifactSource.Download, "真实下载验证",
                fileName: spec.FileName, expectedMd5: spec.ExpectedMd5);
            Console.WriteLine($"真实下载：{downloadedRecord.Version} · {downloadedRecord.Size} bytes · MD5 {downloadedRecord.Md5}");
            var lib = Folder("real lib");
            var target = Path.Combine(lib, "main.min.js");
            await File.WriteAllTextAsync(target, "module.exports='before real check';");
            await store.InstallAsync(downloadedRecord.Id, lib);
            Check((await FileInspector.InspectAsync(target)).Sha256 == downloadedRecord.Sha256, "真实下载安装");
            var original = store.Load().Backups[0];
            if (args.Length > 2)
            {
                var local = await store.ArchiveAsync(args[2], ArtifactSource.Build, "真实本地 webpack 产物验证");
                await store.InstallAsync(local.Id, lib);
                Check((await FileInspector.InspectAsync(target)).Sha256 == local.Sha256, "真实本地产物校验与安装");
                Console.WriteLine($"真实本地产物：{local.Version} · {local.Size} bytes · SHA-256 {local.Sha256}");
            }
            await store.RestoreAsync(original.Id, lib);
            Check(await File.ReadAllTextAsync(target) == "module.exports='before real check';", "真实产物安装后恢复");
        }
        finally { File.Delete(downloaded); }
    }

    private static async Task BuildChecks()
    {
        var project = Folder("fixture project with spaces");
        await Command("git", ["init", "-b", "test-branch"], project);
        await Command("git", ["config", "user.name", "Local Check"], project);
        await Command("git", ["config", "user.email", "check@example.invalid"], project);
        await File.WriteAllTextAsync(Path.Combine(project, "package.json"), "{\"name\":\"local-check\",\"scripts\":{\"buildLb\":\"node fixture.cjs\"}}");
        await File.WriteAllTextAsync(Path.Combine(project, "fixture.cjs"), """
            const fs = require('fs');
            const cp = require('child_process');
            const mode = fs.readFileSync('mode.txt', 'utf8');
            fs.mkdirSync('build', {recursive:true});
            if (mode === 'none') process.exit(0);
            fs.writeFileSync('build/v1.0.0_main.min.js', mode === 'syntax' ? 'const = ;' : "module.exports = 'fresh';");
            if (mode === 'multiple') fs.writeFileSync('build/v2.0.0_main.min.js', 'module.exports=2;');
            if (mode === 'failed') process.exit(7);
            if (mode === 'changed') cp.execFileSync('git', ['checkout', '-b', 'changed']);
            if (mode === 'wait') setInterval(() => {}, 1000);
            """);
        await File.WriteAllTextAsync(Path.Combine(project, ".gitignore"), "build/\n.ads-work-build.lock\n");
        await File.WriteAllTextAsync(Path.Combine(project, "mode.txt"), "ok");
        await Command("git", ["add", "."], project);
        await Command("git", ["commit", "-m", "本地测试夹具"], project);
        var build = Path.Combine(project, "build");
        Directory.CreateDirectory(build);
        var old = Path.Combine(build, "v1.0.0_main.min.js");
        var other = Path.Combine(build, "v0.0.1_main.min.js");
        var mode = Path.Combine(project, "mode.txt");
        await File.WriteAllTextAsync(old, "module.exports = 'old';");
        await File.WriteAllTextAsync(other, "module.exports = 'historic';");
        var service = new BuildService();
        var result = await service.BuildAsync(project);
        Check(result.Branch == "test-branch" && await File.ReadAllTextAsync(result.ArtifactPath) == "module.exports = 'fresh';", "真实当前分支打包且不用同名旧包");
        Check(await File.ReadAllTextAsync(other) == "module.exports = 'historic';", "其他版本保留");
        foreach (var scenario in new[] { "none", "syntax", "failed", "multiple" })
        {
            await File.WriteAllTextAsync(mode, scenario);
            await Reject(() => service.BuildAsync(project), "构建 " + scenario);
            Check(await File.ReadAllTextAsync(old) == "module.exports = 'fresh';", "失败恢复同名旧产物 " + scenario);
            Check(await File.ReadAllTextAsync(other) == "module.exports = 'historic';", "失败恢复其他版本 " + scenario);
            Check(!File.Exists(Path.Combine(project, ".ads-work-build.lock")), "构建锁已清除");
            var extra = Path.Combine(build, "v2.0.0_main.min.js");
            if (File.Exists(extra)) File.Delete(extra);
        }
        await File.WriteAllTextAsync(mode, "wait");
        using (var token = new CancellationTokenSource(800))
            await Reject(() => service.BuildAsync(project, token: token.Token), "取消打包");
        Check(await File.ReadAllTextAsync(old) == "module.exports = 'fresh';", "取消恢复旧产物");
        await File.WriteAllTextAsync(mode, "changed");
        await Reject(() => service.BuildAsync(project), "构建中换分支");
        Check(await File.ReadAllTextAsync(old) == "module.exports = 'fresh';", "分支变化保留旧产物");
        await File.WriteAllTextAsync(Path.Combine(project, ".ads-work-build.lock"), "");
        await Reject(() => service.BuildAsync(project), "并发构建锁");
        File.Delete(Path.Combine(project, ".ads-work-build.lock"));
        Check(!Directory.GetDirectories(build, ".ads-work-previous-*").Any(), "暂存目录清理");
    }

    private static Task<string> Command(string file, string[] args, string cwd)
        => Runner.RunAsync(file, args, cwd, TimeSpan.FromSeconds(30), null, CancellationToken.None);

    private static async Task ProcessChecks()
    {
        await Reject(() => Command("ads-work-missing-command-000", [], Root), "缺少命令友好报错");
        await Reject(() => Command("node", ["-e", "console.error('failure');process.exit(9)"], Root), "非零退出码");
        await Reject(() => Runner.RunAsync("node", ["-e", "setInterval(()=>{},1000)"], Root,
            TimeSpan.FromMilliseconds(150), null, CancellationToken.None), "命令超时");
        var heartbeat = Path.Combine(Root, "child-heartbeat.txt");
        var pidPath = Path.Combine(Root, "child-pid.txt");
        var child = "setInterval(()=>require('fs').appendFileSync(" + JsonSerializer.Serialize(heartbeat) + ",'x'),40)";
        var script = "const fs=require('fs'),cp=require('child_process');const child=cp.spawn(process.execPath,['-e'," +
            JsonSerializer.Serialize(child) + "],{stdio:'inherit'});fs.writeFileSync(" + JsonSerializer.Serialize(pidPath) + ",String(child.pid));setInterval(()=>{},1000)";
        using var cancellation = new CancellationTokenSource();
        var running = Runner.RunAsync("node", ["-e", script], Root, TimeSpan.FromSeconds(10), null, cancellation.Token);
        for (var i = 0; i < 100 && (!File.Exists(heartbeat) || !File.Exists(pidPath)); i++) await Task.Delay(40);
        Check(File.Exists(heartbeat) && File.Exists(pidPath), "子进程已启动");
        cancellation.Cancel();
        await Reject(async () => { _ = await running; }, "取消进程");
        var length = new FileInfo(heartbeat).Length;
        await Task.Delay(250);
        Check(new FileInfo(heartbeat).Length == length, "取消后子进程不再写文件");
    }

    private sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => respond(request, cancellationToken);
    }
}
