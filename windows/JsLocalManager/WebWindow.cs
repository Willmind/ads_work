using AdsWorkJs.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Reflection;
using System.Text.Json;

namespace AdsWorkJs;

internal sealed class WebWindow : Form
{
    private readonly WebView2 browser = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(247, 248, 250) };
    private readonly DesktopController controller;
    private readonly System.Windows.Forms.Timer closingTimer = new() { Interval = 100 };
    private bool closeWhenIdle;
    private bool ready;
    internal WebView2 Browser => browser;

    internal WebWindow(string? dataRoot = null)
    {
        Text = "AdsWork JS 本地管理 · 0.6.0";
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(1100, 880); MinimumSize = new Size(600, 480);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        controller = new DesktopController(this, dataRoot ?? DataLocation.DefaultRoot, Publish);
        Controls.Add(browser);
        Shown += async (_, _) =>
        {
            var area = Screen.FromControl(this).WorkingArea;
            MinimumSize = new Size(Math.Min(MinimumSize.Width, area.Width - 32), Math.Min(MinimumSize.Height, area.Height - 32));
            Size = new Size(Math.Min(Width, area.Width - 32), Math.Min(Height, area.Height - 32));
            await InitializeAsync(dataRoot ?? DataLocation.DefaultRoot);
        };
        FormClosing += (_, args) =>
        {
            if (!controller.Busy) return;
            args.Cancel = true; closeWhenIdle = true; controller.Cancel(); closingTimer.Start();
        };
        closingTimer.Tick += (_, _) => { if (closeWhenIdle && !controller.Busy) { closingTimer.Stop(); Close(); } };
        FormClosed += (_, _) => { closingTimer.Dispose(); controller.Dispose(); browser.Dispose(); };
    }

    private async Task InitializeAsync(string root)
    {
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(root, "WebView2"));
            await browser.EnsureCoreWebView2Async(environment);
            if (IsDisposed || browser.IsDisposed) return;
            var core = browser.CoreWebView2;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsWebMessageEnabled = true;
            core.Settings.IsBuiltInErrorPageEnabled = false;
            core.NavigationStarting += (_, args) => { if (args.Uri != UiProtocol.Page) args.Cancel = true; };
            core.FrameNavigationStarting += (_, args) => args.Cancel = true;
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.DownloadStarting += (_, args) => args.Cancel = true;
            core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += ServeAsset;
            core.WebMessageReceived += ReceiveMessage;
            core.ProcessFailed += (_, _) =>
            {
                ready = false;
                controller.Cancel();
                ShowFallback(new UserVisibleException("网页组件异常退出，请重新打开工具。已保存的 JS 和备份会保留。"));
            };
            ready = true;
            core.Navigate(UiProtocol.Page);
        }
        catch (Exception error) { ShowFallback(error); }
    }

    private void ServeAsset(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        var uri = new Uri(args.Request.Uri);
        var name = uri.AbsolutePath.TrimStart('/');
        var assets = new Dictionary<string, string>
        {
            ["index.html"] = "text/html", ["styles.css"] = "text/css", ["app.js"] = "text/javascript",
            ["bridge.js"] = "text/javascript", ["preview.js"] = "text/javascript", ["motion.js"] = "text/javascript", ["logo.svg"] = "image/svg+xml", ["icons.svg"] = "image/svg+xml"
        };
        if (args.Request.Method != "GET" || uri.Scheme != "https" || uri.Host != "adswork.local" ||
            uri.Port != 443 || uri.Query.Length != 0 || !assets.TryGetValue(name, out var mime))
        {
            args.Response = browser.CoreWebView2.Environment.CreateWebResourceResponse(null, 403, "Forbidden", "");
            return;
        }
        var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("WebUI." + name);
        args.Response = browser.CoreWebView2.Environment.CreateWebResourceResponse(stream, stream is null ? 404 : 200,
            stream is null ? "Not Found" : "OK", $"Content-Type: {mime}; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n");
    }

    private async void ReceiveMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        UiRequest request;
        try { request = UiProtocol.Parse(args.Source, args.WebMessageAsJson); }
        catch (Exception error) when (error is JsonException or UserVisibleException or ArgumentException) { return; }
        try
        {
            var result = await controller.HandleAsync(request);
            Send(new { id = request.Id, ok = true, data = result });
        }
        catch (Exception error) { Send(new { id = request.Id, ok = false, error = error.Message }); }
    }

    private void Publish(string name, object data) => Send(new { type = "event", @event = name, data });
    private void Send(object message)
    {
        if (!ready || IsDisposed || browser.IsDisposed) return;
        try
        {
            if (browser.CoreWebView2.Source == UiProtocol.Page)
                browser.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(message, UiProtocol.Json));
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            ready = false;
            controller.Cancel();
            ShowFallback(error);
        }
    }

    private void ShowFallback(Exception error)
    {
        if (IsDisposed) return;
        ready = false; browser.Visible = false;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(32), WrapContents = false, AutoScroll = true };
        panel.Controls.Add(new Label { Text = "无法启动网页界面", AutoSize = true, Font = new Font("Microsoft YaHei UI", 16, FontStyle.Bold) });
        panel.Controls.Add(new Label { Text = "本地配置和历史记录仍保留。若尚未安装 Microsoft Edge WebView2，请先安装，再重新打开工具。\n\n" + error.Message, AutoSize = true, MaximumSize = new Size(700, 0), Margin = new Padding(0, 20, 0, 20) });
        var install = new Button { Text = "安装 WebView2 运行环境…", AutoSize = true, Padding = new Padding(10) };
        install.Click += (_, _) => RuntimeInstaller.Start(this);
        panel.Controls.Add(install); Controls.Add(panel); panel.BringToFront();
    }
}
