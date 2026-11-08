using System.Text.Json.Nodes;

namespace STS2MobileIos.Patches;

/// <summary>
/// 启动器 → 游戏的一次性指令（三端规范 §3.3）。纯解析，不依赖 Godot，便于离线测试。
/// { "v": 1, "type": "host|join", "created": 1762650000, "online": true,
///   "host": "...", "port": 33774, "nickname": "...", "playerId": "..." }
/// </summary>
public sealed class PendingAction
{
    public const int Version = 1;
    public const long MaxAgeSeconds = 600;

    public string Type { get; private init; }
    public long Created { get; private init; }
    public bool Online { get; private init; }
    public string Host { get; private init; }
    public int Port { get; private init; }
    public string Nickname { get; private init; }
    public string PlayerId { get; private init; }

    /// <summary>用户可读的中文错误；为 null 表示解析成功。</summary>
    public string Error { get; private init; }
    /// <summary>true 表示指令已过期，只写日志、不弹窗。</summary>
    public bool Expired { get; private init; }

    public static PendingAction Parse(string json, DateTimeOffset now)
    {
        JsonObject root;
        try { root = JsonNode.Parse(json) as JsonObject; }
        catch (Exception) { root = null; }
        if (root == null) return Fail("联机指令不是有效的 JSON，已丢弃。请回到启动器重新创建或加入房间。");

        var version = ReadLong(root["v"]);
        // 旧版 iPad 启动器只写 type/host/port；没有 v 的按 v1 处理，但必须有 created 才能判断是否过期。
        if (version.HasValue && version.Value != Version)
            return Fail($"联机指令版本 {version.Value} 不受支持（游戏补丁只认 v{Version}），请更新启动器或游戏补丁。");
        var type = ReadString(root["type"]);
        if (type != "host" && type != "join")
            return Fail($"未知的联机指令类型「{type ?? "(空)"}」。");
        var created = ReadLong(root["created"]);
        if (!created.HasValue)
            return new PendingAction { Type = type, Expired = true, Error = "联机指令缺少 created 时间，按过期处理。" };
        var age = now.ToUnixTimeSeconds() - created.Value;
        if (age > MaxAgeSeconds || age < -MaxAgeSeconds)
            return new PendingAction { Type = type, Created = created.Value, Expired = true, Error = $"联机指令已过期（{age} 秒前创建，上限 {MaxAgeSeconds} 秒），已丢弃。" };

        var action = new PendingAction
        {
            Type = type,
            Created = created.Value,
            Online = ReadBool(root["online"]) ?? true,
            Host = ReadString(root["host"])?.Trim(),
            Port = (int)(ReadLong(root["port"]) ?? 0),
            Nickname = ReadString(root["nickname"]),
            PlayerId = ReadString(root["playerId"]) ?? ReadLong(root["playerId"])?.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };
        if (type == "join")
        {
            if (string.IsNullOrWhiteSpace(action.Host) || action.Host.Any(char.IsWhiteSpace) || action.Host.Length > 253)
                return Fail("房间地址无效。", type);
            if (action.Port is <= 0 or > 65535)
                return Fail($"房间端口 {action.Port} 无效（应为 1–65535）。", type);
        }
        return action;
    }

    public static PendingAction Failure(string message) => Fail(message);

    private static PendingAction Fail(string message, string type = null) => new() { Type = type, Error = message };

    private static string ReadString(JsonNode node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static bool? ReadBool(JsonNode node) =>
        node is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;

    private static long? ReadLong(JsonNode node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<long>(out var number)) return number;
        if (value.TryGetValue<double>(out var real) && real == Math.Floor(real) && Math.Abs(real) < 9e15) return (long)real;
        if (value.TryGetValue<string>(out var text) && long.TryParse(text, out number)) return number;
        return null;
    }
}
