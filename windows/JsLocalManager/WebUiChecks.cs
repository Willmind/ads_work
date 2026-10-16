using AdsWorkJs.Core;
using Microsoft.Web.WebView2.Core;
using System.Text.Json;

namespace AdsWorkJs;
internal static class WebUiChecks
{
    internal static int Run(string? reportPath)
    {
        var report = reportPath ?? Path.Combine(Path.GetTempPath(), "AdsWork-WebUI-" + Guid.NewGuid().ToString("N"));
        var data = Path.Combine(Path.GetTempPath(), "AdsWork-WebUI-data-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(report); Directory.CreateDirectory(data);
        var errors = new List<string>();
        var source = Path.Combine(data, "v2.8.9.4_main.min.js");
        File.WriteAllText(source, "module.exports='web ui check';");
        new ArchiveStore(data).ArchiveAsync(source, ArtifactSource.Build, "界面验证备注", "test/layout").GetAwaiter().GetResult();
        using var form = new WebWindow(data);
        form.Shown += async (_, _) =>
        {
            try
            {
                var loaded = false;
                for (var i = 0; i < 150; i++)
                {
                    await Task.Delay(200);
                    if (form.Browser.CoreWebView2 is null) continue;
                    if (await form.Browser.ExecuteScriptAsync("document.documentElement.dataset.ready === 'true'") == "true") { loaded = true; break; }
                }
                if (!loaded) throw new IOException("页面或 WebView2 未在 30 秒内就绪，请检查 WebView2 运行环境。");
                foreach (var width in new[] { 1100, 760 })
                foreach (var zoom in new[] { 1.0, 1.25, 1.5 })
                {
                    form.ClientSize = new Size(width, 880);
                    form.Browser.ZoomFactor = zoom;
                    foreach (var mode in new[] { "build", "download", "file" })
                    {
                        await form.Browser.ExecuteScriptAsync($"document.querySelector('#tab-{mode}').click()");
                        await Task.Delay(280);
                        var json = await form.Browser.ExecuteScriptAsync("""
                            JSON.stringify({
                              connected: !!window.chrome?.webview,
                              ready: document.documentElement.dataset.ready,
                              overflow: document.documentElement.scrollWidth > innerWidth + 1,
                              clipped: [...document.querySelectorAll('button')].filter(b=>b.getClientRects().length && (b.scrollWidth>b.clientWidth+2 || b.scrollHeight>b.clientHeight+2)).map(b=>b.textContent),
                              missingIcons: [...document.querySelectorAll('svg.icon')].filter(s=>s.getClientRects().length && (!s.querySelector('use').getBBox().width || !s.querySelector('use').getBBox().height)).map(s=>s.querySelector('use').getAttribute('href')),
                              rows: document.querySelectorAll('#records tr').length
                            })
                            """);
                        using var result = JsonDocument.Parse(JsonSerializer.Deserialize<string>(json)!);
                        var value = result.RootElement;
                        var name = $"width-{width}-zoom-{zoom:0.00}-{mode}";
                        if (!value.GetProperty("connected").GetBoolean() || value.GetProperty("ready").GetString() != "true" ||
                            value.GetProperty("overflow").GetBoolean() || value.GetProperty("clipped").GetArrayLength() != 0 ||
                            value.GetProperty("missingIcons").GetArrayLength() != 0 || value.GetProperty("rows").GetInt32() != 1)
                            errors.Add(name + ": " + value.GetRawText());
                        await using var output = File.Create(Path.Combine(report, name + ".png"));
                        await form.Browser.CoreWebView2!.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, output);
                    }
                }
            }
            catch (Exception error) { errors.Add(error.ToString()); }
            finally
            {
                File.WriteAllText(Path.Combine(report, "report.json"), JsonSerializer.Serialize(new { passed = errors.Count == 0, errors, scope = "Windows WebView2 实际加载、本地桥接、宽窄窗口与 100%/125%/150% 浏览器缩放。不同系统 DPI 需另行实测。" }, new JsonSerializerOptions { WriteIndented = true }));
                form.Close();
            }
        };
        Application.Run(form);
        // WebView2 may keep its test profile briefly; only remove fixture files, never user data.
        try { File.Delete(source); }
        catch (IOException error) { File.AppendAllText(Path.Combine(report, "cleanup.txt"), error.Message); }
        return errors.Count == 0 ? 0 : 1;
    }
}
