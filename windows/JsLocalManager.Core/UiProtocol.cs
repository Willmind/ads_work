using System.Text.Json;

namespace AdsWorkJs.Core;

public sealed record UiRequest(string Id, string Action, JsonElement Args);

public static class UiProtocol
{
    public const string Page = "https://adswork.local/index.html";
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly HashSet<string> Actions = ["state", "buildFiles", "clearBuild", "saveSettings", "chooseProject", "chooseLibrary", "buildSave", "buildInstall", "download", "import", "install", "updateMetadata", "restore", "openArchive", "copyLog", "cancel"];

    public static UiRequest Parse(string origin, string json)
    {
        if (origin != Page || json.Length > 65536) throw new UserVisibleException("页面来源或消息长度无效。");
        var request = JsonSerializer.Deserialize<UiRequest>(json, Json) ?? throw new UserVisibleException("本地请求无效。");
        if (!Guid.TryParseExact(request.Id, "D", out _) || !Actions.Contains(request.Action) || request.Args.ValueKind != JsonValueKind.Object)
            throw new UserVisibleException("不支持的本地请求。");
        return request;
    }

    public static string Text(JsonElement args, string key, int limit = 4000)
    {
        if (!args.TryGetProperty(key, out var value)) return "";
        if (value.ValueKind != JsonValueKind.String) throw new UserVisibleException("请求参数类型无效。");
        var text = value.GetString() ?? "";
        if (text.Length > limit) throw new UserVisibleException("输入内容过长。");
        return text;
    }

    public static Guid Id(JsonElement args)
    {
        if (!Guid.TryParse(Text(args, "id", 36), out var id)) throw new UserVisibleException("请选择有效的历史或备份记录。");
        return id;
    }
}
