using AdsWorkJs.Core;

namespace AdsWorkJs;
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length > 0 && args[0] == "--web-check") return WebUiChecks.Run(args.ElementAtOrDefault(1));
        try { Application.Run(new WebWindow()); return 0; }
        catch (Exception error)
        {
            MessageBox.Show("工具启动失败：" + error.Message + "\n\n本地数据目录：" + DataLocation.DefaultRoot,
                "AdsWork JS 本地管理", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
