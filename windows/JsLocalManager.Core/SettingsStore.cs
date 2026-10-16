using System.Text.Json;

namespace AdsWorkJs.Core;

public sealed class SettingsStore(string root)
{
    private readonly string path = Path.Combine(root, "settings.json");

    public AppSettings Load()
    {
        if (!File.Exists(path)) return new AppSettings();
        return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path))
            ?? throw new UserVisibleException("本地配置无效，请检查 settings.json。");
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(root);
        AtomicJson.Write(path, settings);
    }
}

internal static class AtomicJson
{
    internal static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    internal static void Write<T>(string path, T value)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value, Options);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
