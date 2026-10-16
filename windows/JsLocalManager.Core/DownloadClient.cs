using System.Net;
using System.Text.RegularExpressions;

namespace AdsWorkJs.Core;

public sealed partial record DownloadSpec(Uri Url, string FileName, string? ExpectedMd5)
{
    public static DownloadSpec Parse(string text, string manualMd5 = "")
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var url) || !IsAllowed(url) || url.Fragment.Length != 0)
            throw new UserVisibleException("请粘贴 version.adspower.net 的完整 HTTPS JS 下载链接，不是后台页面地址。");
        var name = Uri.UnescapeDataString(url.Segments.Last());
        if (!JsName().IsMatch(name)) throw new UserVisibleException("链接应指向 .js 文件，支持末尾附带 32 位 MD5。");
        var supplied = manualMd5.Trim().ToLowerInvariant();
        if (supplied.Length != 0 && !Md5Pattern().IsMatch(supplied)) throw new UserVisibleException("MD5 必须是 32 位十六进制字符，也可留空。");
        var match = EmbeddedHash().Match(name);
        var embedded = match.Success ? match.Value.ToLowerInvariant() : null;
        if (supplied.Length != 0 && embedded is not null && supplied != embedded)
            throw new UserVisibleException("填写的 MD5 与链接中的 MD5 不一致。");
        return new DownloadSpec(url, name, supplied.Length == 0 ? embedded : supplied);
    }

    public static bool IsAllowed(Uri uri) => uri.Scheme == Uri.UriSchemeHttps &&
        uri.Host.Equals("version.adspower.net", StringComparison.OrdinalIgnoreCase) &&
        uri.UserInfo.Length == 0 && uri.Port == 443;

    [GeneratedRegex(@"\.js(?:[a-fA-F0-9]{32})?$")] private static partial Regex JsName();
    [GeneratedRegex(@"^[a-f0-9]{32}$")] private static partial Regex Md5Pattern();
    [GeneratedRegex(@"(?<=\.js)[a-fA-F0-9]{32}$")] private static partial Regex EmbeddedHash();
}

public sealed class DownloadClient : IDisposable
{
    private readonly HttpClient client;

    public DownloadClient(HttpMessageHandler? handler = null)
    {
        handler ??= new HttpClientHandler
        {
            AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<string> DownloadAsync(DownloadSpec spec, IProgress<OperationEvent>? progress = null,
        CancellationToken token = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(120));
        var temporary = Path.Combine(Path.GetTempPath(), "ads-js-download-" + Guid.NewGuid().ToString("N") + ".js");
        try
        {
            var current = spec.Url;
            for (var redirects = 0; redirects <= 5; redirects++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                request.Headers.Accept.ParseAdd("application/javascript, text/javascript, application/octet-stream");
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                if ((int)response.StatusCode is >= 300 and < 400)
                {
                    var location = response.Headers.Location;
                    var next = location is null ? null : location.IsAbsoluteUri ? location : new Uri(current, location);
                    if (next is null || !DownloadSpec.IsAllowed(next))
                        throw new UserVisibleException("下载跳转到不支持的地址，已停止。");
                    current = next;
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK)
                    throw new UserVisibleException("下载失败：HTTP " + (int)response.StatusCode + "，未保存或安装。");
                var mime = response.Content.Headers.ContentType?.MediaType ?? "";
                var length = response.Content.Headers.ContentLength;
                if (mime.Contains("html", StringComparison.OrdinalIgnoreCase) ||
                    mime.Contains("json", StringComparison.OrdinalIgnoreCase) ||
                    mime.Contains("xml", StringComparison.OrdinalIgnoreCase) || length > FileInspector.MaximumSize)
                    throw new UserVisibleException("服务器返回网页、错误内容或超过 100 MB 的文件，已停止下载。");
                await using var input = await response.Content.ReadAsStreamAsync(timeout.Token);
                await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    var buffer = new byte[65536];
                    long total = 0;
                    var last = DateTime.UtcNow;
                    while (true)
                    {
                        var count = await input.ReadAsync(buffer, timeout.Token);
                        if (count == 0) break;
                        total += count;
                        if (total > FileInspector.MaximumSize) throw new UserVisibleException("下载超过 100 MB，已停止。");
                        await output.WriteAsync(buffer.AsMemory(0, count), timeout.Token);
                        if (DateTime.UtcNow - last > TimeSpan.FromMilliseconds(300))
                        {
                            progress?.Report(new("下载 JS", $"已下载 {total / 1048576.0:F1} MB"));
                            last = DateTime.UtcNow;
                        }
                    }
                }
                var digest = await FileInspector.InspectAsync(temporary, token: timeout.Token);
                if (spec.ExpectedMd5 is not null && digest.Md5 != spec.ExpectedMd5)
                    throw new UserVisibleException("下载文件 MD5 不一致，未归档或安装。");
                return temporary;
            }
            throw new UserVisibleException("下载跳转次数过多，已停止。");
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            throw new UserVisibleException("下载超过 120 秒，已停止，未安装。");
        }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            throw;
        }
    }

    public void Dispose() => client.Dispose();
}
