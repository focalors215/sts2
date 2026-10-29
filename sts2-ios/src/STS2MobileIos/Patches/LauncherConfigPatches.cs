using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Godot;

namespace STS2MobileIos.Patches;

/// <summary>
/// Owns the iOS launcher's small, user-editable network configuration.  The
/// file is deliberately outside the game's save tree so changing a LAN peer
/// identity can never rewrite the identity already recorded in a run save.
/// </summary>
public static class LauncherConfigPatches
{
    public const int DefaultPort = 33771;
    private static readonly object Gate = new();
    private static JsonObject _root;
    // Set when an existing config could not be understood. The file is then left
    // untouched so a hand-editing mistake can never destroy network.playerId.
    private static bool _persistBlocked;

    public static string ConfigPath => Path.Combine(OS.GetUserDataDir(), "Launcher", "config.json");

    public static string Nickname
    {
        get { lock (Gate) return GetString("nickname", "Player"); }
        set { lock (Gate) { Network["nickname"] = Normalize(value, 32, "Player"); Save(); } }
    }

    public static string Host
    {
        get { lock (Gate) return GetString("host", string.Empty); }
        set { lock (Gate) { Network["host"] = (value ?? string.Empty).Trim(); Save(); } }
    }

    public static int Port
    {
        get
        {
            lock (Gate)
            {
                var value = TryInt(Network["port"], out var port) ? port : DefaultPort;
                return value is > 0 and <= 65535 ? value : DefaultPort;
            }
        }
        set
        {
            if (value is <= 0 or > 65535)
                throw new ArgumentOutOfRangeException(nameof(value), "Port must be between 1 and 65535.");
            lock (Gate) { Network["port"] = value; Save(); }
        }
    }

    public static ulong LocalPeerId
    {
        get
        {
            lock (Gate)
            {
                if (ulong.TryParse(Network["playerId"]?.ToString(), out var saved) && saved > 0)
                    return saved;
                var generated = CreatePeerId();
                Network["playerId"] = generated.ToString(System.Globalization.CultureInfo.InvariantCulture);
                Save();
                PatchHelper.Log($"Created persistent LAN peer ID {generated}.");
                return generated;
            }
        }
    }

    public static JsonArray ResourceMods
    {
        get
        {
            lock (Gate)
                { EnsureLoaded(); return _root["resourceMods"] as JsonArray ?? new JsonArray(); }
        }
    }

    private static JsonObject Network
    {
        get
        {
            EnsureLoaded();
            var network = _root["network"] as JsonObject;
            if (network == null)
                _root["network"] = network = new JsonObject();
            return network;
        }
    }

    private static string GetString(string key, string fallback)
    {
        var value = Network[key] is JsonValue node && node.TryGetValue<string>(out var text) ? text : null;
        return string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
    }

    private static bool TryInt(JsonNode node, out int value)
    {
        value = 0;
        if (node is not JsonValue json) return false;
        if (json.TryGetValue<int>(out value)) return true;
        if (json.TryGetValue<double>(out var d) && d == Math.Floor(d) && d >= int.MinValue && d <= int.MaxValue)
        { value = (int)d; return true; }
        return false;
    }

    private static void EnsureLoaded()
    {
        if (_root != null)
            return;

        try
        {
            if (File.Exists(ConfigPath))
            {
                var parsed = JsonNode.Parse(File.ReadAllText(ConfigPath)) as JsonObject;
                if (parsed != null && TryInt(parsed["schemaVersion"], out var schema) && schema == 1)
                    _root = parsed;
                else
                {
                    _persistBlocked = true;
                    PatchHelper.Log("Launcher config has an unsupported shape; using defaults and leaving the file untouched.");
                }
            }
        }
        catch (Exception exception)
        {
            _persistBlocked = true;
            PatchHelper.Log($"Could not read launcher config; using defaults and leaving the file untouched: {exception.Message}");
        }

        if (_root == null)
        {
            _root = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["network"] = new JsonObject
                {
                    ["nickname"] = "Player",
                    ["host"] = string.Empty,
                    ["port"] = DefaultPort,
                },
                ["resourceMods"] = new JsonArray(),
            };
        }
        else if (_root["network"] is not JsonObject)
            _root["network"] = new JsonObject();

        var network = _root["network"]!.AsObject();
        network["nickname"] ??= "Player";
        network["host"] ??= string.Empty;
        network["port"] ??= DefaultPort;
        _root["resourceMods"] ??= network["resourceMods"]?.DeepClone() ?? new JsonArray();
        network.Remove("resourceMods");
        Save();
    }

    private static void Save()
    {
        if (_persistBlocked) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
            var temporaryPath = ConfigPath + ".tmp";
            File.WriteAllText(temporaryPath, _root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporaryPath, ConfigPath, overwrite: true);
        }
        catch (Exception exception)
        {
            PatchHelper.Log($"Could not write launcher config: {exception.Message}");
        }
    }

    private static ulong CreatePeerId()
    {
        Span<byte> bytes = stackalloc byte[sizeof(ulong)];
        ulong result;
        do
        {
            System.Security.Cryptography.RandomNumberGenerator.Fill(bytes);
            result = BitConverter.ToUInt64(bytes) & 0x7FFFFFFFFFFFFFFFUL;
        } while (result <= 1);
        return result;
    }

    private static string Normalize(string value, int maxLength, string fallback)
    {
        var normalized = (value ?? string.Empty).Trim().Normalize(System.Text.NormalizationForm.FormKC);
        if (normalized.Length > maxLength)
            normalized = normalized[..maxLength];
        return string.IsNullOrWhiteSpace(normalized) ? fallback : normalized;
    }
}
