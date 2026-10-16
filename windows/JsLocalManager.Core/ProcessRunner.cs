using System.Diagnostics;
using System.Text;

namespace AdsWorkJs.Core;

public interface ICommandRunner
{
    Task<string> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory,
        TimeSpan timeout, IProgress<OperationEvent>? progress, CancellationToken token);
}

public sealed class ProcessRunner : ICommandRunner
{
    public async Task<string> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory,
        TimeSpan timeout, IProgress<OperationEvent>? progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var start = new ProcessStartInfo(executable)
        {
            WorkingDirectory = workingDirectory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        foreach (var key in start.Environment.Keys.Where(key => key.StartsWith("GIT_", StringComparison.Ordinal)).ToArray())
            start.Environment.Remove(key);
        start.Environment["CI"] = "1";
        start.Environment["NO_COLOR"] = "1";
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token);
        linked.CancelAfter(timeout);
        using var process = new Process { StartInfo = start };
        var started = false;
        var tail = new StringBuilder();
        var gate = new object();
        try
        {
            try { process.Start(); started = true; }
            catch (System.ComponentModel.Win32Exception ex)
            {
                throw new UserVisibleException("无法启动 " + Path.GetFileName(executable) + "。请确认已安装 Git/Node.js，并重新打开工具。", ex);
            }
            process.StandardInput.Close();
            async Task ReadAsync(StreamReader reader)
            {
                while (await reader.ReadLineAsync(linked.Token) is { } line)
                {
                    var value = line.Length > 8000 ? line[..8000] + "（已截断）" : line;
                    lock (gate)
                    {
                        tail.AppendLine(value);
                        if (tail.Length > 16000) tail.Remove(0, tail.Length - 12000);
                    }
                    progress?.Report(new("打包当前分支", value, IsLog: true));
                }
            }
            var output = ReadAsync(process.StandardOutput);
            var errors = ReadAsync(process.StandardError);
            await Task.WhenAll(process.WaitForExitAsync(linked.Token), output, errors);
            token.ThrowIfCancellationRequested();
            if (process.ExitCode != 0)
                throw new UserVisibleException("命令失败，退出码 " + process.ExitCode + "。\n" + tail.ToString().Trim());
            return tail.ToString().Trim();
        }
        catch
        {
            if (started && !process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                using var stopping = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await process.WaitForExitAsync(stopping.Token);
            }
            if (!token.IsCancellationRequested && linked.IsCancellationRequested)
                throw new UserVisibleException("命令执行超时（" + (int)timeout.TotalSeconds + " 秒），已停止，未用于安装。");
            throw;
        }
    }
}
