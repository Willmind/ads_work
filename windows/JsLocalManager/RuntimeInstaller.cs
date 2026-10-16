using System.Diagnostics;
using System.Security.Cryptography;
namespace AdsWorkJs;
internal static class RuntimeInstaller
{
    internal static void Start(Form owner)
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "MicrosoftEdgeWebview2Setup.exe");
            if (!File.Exists(path)) throw new IOException("请将 ZIP 完整解压后运行，缺少随包提供的 WebView2 安装程序。");
            using var stream = File.OpenRead(path);
            if (Convert.ToHexStringLower(SHA256.HashData(stream)) != "baa78c71c5615533a1ee0c4d2ca2ea3fd24dae01965f9033ac530a61b5aa93a0")
                throw new IOException("WebView2 安装程序校验不一致，请重新获取完整发布包。");
            stream.Close();
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception error) { MessageBox.Show(owner, error.Message, "WebView2", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
