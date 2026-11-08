using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;

namespace STS2Mobile.Patches;

/// <summary>
/// Pure (Godot-free) parts of the cross-platform online room contract, kept
/// separate so tests/OnlineRoomProtocol.Tests can exercise them without the game:
/// pending-action.json parsing (doc/architecture/cross-platform-parity.md §3.3),
/// multiplayer save identity (§3.4) and the shared log line format (§5.1).
/// </summary>
public static class OnlineRoomProtocol
{
    /// <summary>ENetHost.NetId / ENetClient.HostNetId are hard-coded to 1 in the original game.</summary>
    public const ulong HostNetId = 1UL;

    /// <summary>pending-action.json older than this is discarded (§3.3).</summary>
    public const long PendingActionMaxAgeSeconds = 600;

    public enum SaveRole
    {
        /// <summary>The save contains neither the local playerId nor the host ID 1.</summary>
        Mismatch,
        /// <summary>This device was the host of the saved run (its player is NetId 1).</summary>
        Host,
        /// <summary>This device joined the saved run with its stable playerId.</summary>
        Joiner,
    }

    public sealed class PendingAction
    {
        public string Type { get; init; } = string.Empty;
        public string Host { get; init; } = string.Empty;
        public int Port { get; init; }
        public long Created { get; init; }
        public bool Online { get; init; } = true;
        public string Nickname { get; init; } = string.Empty;
        public ulong PlayerId { get; init; }
    }

    /// <summary>
    /// Parses pending-action.json. Returns null with a user-facing Chinese error
    /// when the action is unusable (bad JSON, unknown type, expired, bad address).
    /// A missing <c>created</c> is accepted for launchers written before §3.3;
    /// <paramref name="warning"/> then says so.
    /// </summary>
    public static PendingAction ParsePendingAction(string json, long nowUnixSeconds, out string error, out string warning)
    {
        error = null;
        warning = null;
        JsonObject root;
        try
        {
            root = JsonNode.Parse(json ?? string.Empty) as JsonObject;
        }
        catch (Exception exception)
        {
            error = $"联机指令文件无法解析：{exception.Message}";
            return null;
        }
        if (root == null)
        {
            error = "联机指令文件不是 JSON 对象。";
            return null;
        }

        var type = ReadString(root, "type");
        if (type != "host" && type != "join")
        {
            error = $"未知的联机指令类型：{(string.IsNullOrEmpty(type) ? "（空）" : type)}";
            return null;
        }

        var created = ReadLong(root, "created");
        if (created <= 0)
        {
            warning = "联机指令没有 created 字段，按未过期处理。";
        }
        else if (nowUnixSeconds - created > PendingActionMaxAgeSeconds)
        {
            error = $"联机指令已过期（{nowUnixSeconds - created} 秒前创建，上限 {PendingActionMaxAgeSeconds} 秒），已丢弃。请回到启动器重新创建或加入房间。";
            return null;
        }

        var host = ReadString(root, "host").Trim();
        var port = (int)ReadLong(root, "port");
        if (type == "join")
        {
            if (host.Length == 0 || host.Length > 253 || host.Any(c => char.IsWhiteSpace(c) || char.IsControl(c)))
            {
                error = "房间地址无效。";
                return null;
            }
            if (port is <= 0 or > 65535)
            {
                error = $"房间端口无效：{port}";
                return null;
            }
        }

        var playerIdText = ReadString(root, "playerId");
        ulong.TryParse(playerIdText, NumberStyles.None, CultureInfo.InvariantCulture, out var playerId);
        return new PendingAction
        {
            Type = type,
            Host = host,
            Port = port,
            Created = created,
            Online = root["online"] is JsonValue onlineValue && onlineValue.TryGetValue<bool>(out var online) ? online : true,
            Nickname = ReadString(root, "nickname").Trim(),
            PlayerId = IsValidPlayerId(playerId) ? playerId : 0,
        };
    }

    /// <summary>playerId range shared by all launchers: [2, 2^63-1]; 1 is reserved for the ENet host.</summary>
    public static bool IsValidPlayerId(ulong playerId) => playerId > HostNetId && playerId <= long.MaxValue;

    /// <summary>
    /// §3.4: decides which player this device is in a multiplayer save. The
    /// stable playerId is checked first because a joiner's own copy of the save
    /// also contains the original host (1).
    /// </summary>
    public static SaveRole ResolveSaveRole(IEnumerable<ulong> savePlayerIds, ulong stablePlayerId, out ulong localNetId)
    {
        var ids = savePlayerIds?.ToList() ?? new List<ulong>();
        if (IsValidPlayerId(stablePlayerId) && ids.Contains(stablePlayerId))
        {
            localNetId = stablePlayerId;
            return SaveRole.Joiner;
        }
        if (ids.Contains(HostNetId))
        {
            localNetId = HostNetId;
            return SaveRole.Host;
        }
        localNetId = 0;
        return SaveRole.Mismatch;
    }

    public const string SaveMismatchMessage = "这个多人存档不属于当前玩家 ID。请恢复创建存档时的玩家 ID，存档已保留未改动。";

    public const string JoinerCannotHostMessage = "这个多人存档里你是加入方，只能由原房主开房续局。请让原房主创建房间后加入。";

    /// <summary>One launcher log line (§5.1), terminated by '\n'; stack frames are indented by four spaces.</summary>
    public static string FormatLogLine(DateTimeOffset time, char level, string tag, string message, Exception exception)
    {
        var builder = new StringBuilder();
        builder.Append(time.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture));
        builder.Append(' ').Append(level).Append(" [").Append(tag).Append("] ").Append(OneLine(message));
        if (exception != null)
        {
            builder.Append(" | ").Append(exception.GetType().FullName).Append(": ").Append(OneLine(exception.Message));
            AppendStack(builder, exception.StackTrace);
            for (var inner = exception.InnerException; inner != null; inner = inner.InnerException)
            {
                builder.Append('\n').Append("    caused by ").Append(inner.GetType().FullName).Append(": ").Append(OneLine(inner.Message));
                AppendStack(builder, inner.StackTrace);
            }
        }
        return builder.Append('\n').ToString();
    }

    private static void AppendStack(StringBuilder builder, string stack)
    {
        if (string.IsNullOrEmpty(stack))
            return;
        foreach (var raw in stack.Split('\n'))
        {
            var frame = raw.TrimEnd('\r').Trim();
            if (frame.Length > 0)
                builder.Append('\n').Append("    ").Append(frame);
        }
    }

    private static string OneLine(string text) => (text ?? string.Empty).Replace("\r", " ").Replace("\n", " ");

    private static string ReadString(JsonObject root, string key)
    {
        var node = root[key];
        if (node is not JsonValue value)
            return string.Empty;
        if (value.TryGetValue<string>(out var text))
            return text ?? string.Empty;
        return value.ToJsonString().Trim('"');
    }

    private static long ReadLong(JsonObject root, string key)
    {
        if (root[key] is not JsonValue value)
            return 0;
        if (value.TryGetValue<long>(out var number))
            return number;
        if (value.TryGetValue<double>(out var real))
            return (long)real;
        if (value.TryGetValue<string>(out var text) && long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out number))
            return number;
        return 0;
    }
}
