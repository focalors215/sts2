using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Godot;
using MegaCrit.Sts2.Core.Multiplayer;
using FileAccess = System.IO.FileAccess;

namespace STS2MobileIos.Patches;

/// <summary>Loads native-admitted resource packs before NGame enters its tree.</summary>
public static class ResourcePackPatches
{
    private static bool _attempted;
    private static readonly List<string> LoadedPackHashes = new();

    // Preserve the game's own mod handshake and add the effective pack overlay.
    // Pack order matters: later packs can replace resources from earlier packs.
    public static void LocalDefaultPostfix(ref PeerVersionInfo __result)
    {
        if (LoadedPackHashes.Count == 0) return;
        var mods = __result.gameplayAffectingMods == null
            ? new List<string>() : new List<string>(__result.gameplayAffectingMods);
        mods.Add(ResourcePackFingerprint(LoadedPackHashes));
        __result.gameplayAffectingMods = mods;
    }

    public static string ResourcePackFingerprint(IEnumerable<string> orderedHashes)
    {
        // Each admitted digest has exactly 64 hex characters, so newline framing
        // is unambiguous. Normalize casing independently of launcher spelling.
        var input = string.Join("\n", orderedHashes.Select(hash => hash.ToLowerInvariant()));
        return "ios-resource-packs-v1:" + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(input))).ToLowerInvariant();
    }

    public static void EnterTreePrefix()
    {
        if (_attempted) return;
        _attempted = true;
        var entries = new JsonArray();
        var loaded = new JsonArray();
        var status = new JsonObject
        {
            ["schemaVersion"] = 1, ["completed"] = false,
            ["entries"] = entries, ["loadedIds"] = loaded, ["error"] = string.Empty,
            ["updatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O"),
        };
        string documents;
        try { documents = Path.GetFullPath(OS.GetUserDataDir()); }
        catch (Exception e) { PatchHelper.Log($"Resource packs unavailable: {e}"); return; }
        TryWriteStatus(documents, status);
        try
        {
            var configPath = Path.Combine(documents, "Launcher", "config.json");
            RejectSymlinks(documents, configPath);
            if (!File.Exists(configPath)) return;
            var root = JsonNode.Parse(File.ReadAllText(configPath)) as JsonObject
                ?? throw new InvalidDataException("Launcher config must be an object.");
            if (root["schemaVersion"]?.GetValue<int>() != 1)
                throw new InvalidDataException("Unsupported launcher config schema.");
            if (root["resourceMods"] == null) return;
            if (root["resourceMods"] is not JsonArray mods)
                throw new InvalidDataException("resourceMods must be an array.");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in mods)
            {
                var entry = new JsonObject { ["id"] = string.Empty, ["status"] = "failed", ["error"] = string.Empty };
                entries.Add(entry);
                try
                {
                    var mod = item as JsonObject ?? throw new InvalidDataException("Resource mod entry must be an object.");
                    var id = RequiredString(mod, "id");
                    entry["id"] = id;
                    if (id.Length > 128 || id.Any(char.IsControl))
                        throw new InvalidDataException("Invalid resource mod ID.");
                    var configuredPath = RequiredString(mod, "path");
                    entry["path"] = configuredPath;
                    var path = ValidatePackPath(documents, configuredPath);
                    if (!seen.Add(path)) throw new InvalidDataException("Duplicate resource pack path.");
                    var expected = RequiredString(mod, "sha256");
                    entry["sha256"] = expected;
                    if (expected.Length != 64 || expected.Any(c => !char.IsAsciiHexDigit(c)))
                        throw new InvalidDataException("sha256 must contain exactly 64 hexadecimal characters.");
                    var actual = ComputeSha256(path);
                    if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Resource pack SHA256 mismatch.");
                    // No assembly load or mod initializer. The native importer admits
                    // resource-only packs and records the exact hash of those bytes.
                    if (!ProjectSettings.LoadResourcePack(path, replaceFiles: true))
                        throw new InvalidDataException("Godot rejected the resource pack.");
                    LoadedPackHashes.Add(actual);
                    entry["status"] = "loaded";
                    PatchHelper.Log($"Resource pack loaded: {id} ({actual}).");
                }
                catch (Exception e)
                {
                    entry["error"] = e.Message;
                    PatchHelper.Log($"Resource pack failed [{entry["id"]}]: {e}");
                }
                TryWriteStatus(documents, status);
            }
        }
        catch (Exception e)
        {
            status["error"] = e.Message;
            PatchHelper.Log($"Resource pack configuration failed; continuing vanilla startup: {e}");
        }
        finally
        {
            // One MOD can contain several packs. Report a MOD loaded only when
            // every admitted pack in that group loaded successfully.
            foreach (var group in entries.OfType<JsonObject>().GroupBy(e => e["id"]?.GetValue<string>() ?? string.Empty))
                if (group.Key.Length > 0 && group.All(e => e["status"]?.GetValue<string>() == "loaded"))
                    loaded.Add(group.Key);
            status["completed"] = true;
            TryWriteStatus(documents, status);
        }
    }

    private static string RequiredString(JsonObject value, string key)
    {
        if (value[key] is not JsonValue node || !node.TryGetValue<string>(out var text) || string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException($"Resource mod {key} must be a nonempty string.");
        return text;
    }

    // Pure validation/hash helpers deliberately propagate failures to the caller.
    public static string ValidatePackPath(string documents, string input)
    {
        if (string.IsNullOrWhiteSpace(input) || input.IndexOf('\0') >= 0 || input.Contains('\\'))
            throw new InvalidDataException("Invalid resource pack path.");
        if (input.Split('/').Any(p => p == ".." || p == "."))
            throw new InvalidDataException("Resource pack path traversal is forbidden.");
        documents = Path.GetFullPath(documents);
        var root = Path.Combine(documents, "Launcher", "Mods");
        var path = Path.GetFullPath(Path.IsPathRooted(input) ? input : Path.Combine(documents, input));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new InvalidDataException("Resource pack must be inside Documents/Launcher/Mods.");
        if (!string.Equals(Path.GetExtension(path), ".pck", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Only .pck resource packs can be loaded.");
        RejectSymlinks(documents, path);
        if (!File.Exists(path)) throw new FileNotFoundException("Resource pack does not exist.", path);
        return path;
    }

    public static string ComputeSha256(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void RejectSymlinks(string documents, string path)
    {
        var current = Path.GetFullPath(documents);
        var relative = Path.GetRelativePath(current, Path.GetFullPath(path));
        if (relative == ".." || relative.StartsWith("../", StringComparison.Ordinal))
            throw new InvalidDataException("Path is outside Documents.");
        CheckNotLink(current);
        foreach (var component in relative.Split(Path.DirectorySeparatorChar))
        {
            current = Path.Combine(current, component);
            CheckNotLink(current);
        }
    }

    private static void CheckNotLink(string path)
    {
        // LinkTarget also detects dangling links, unlike File.Exists alone.
        if (new FileInfo(path).LinkTarget != null || new DirectoryInfo(path).LinkTarget != null ||
            (File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Symlinks are forbidden in launcher resource paths.");
    }

    private static void TryWriteStatus(string documents, JsonObject status)
    {
        string temporary = null;
        try
        {
            var directory = Path.Combine(documents, "Launcher");
            var path = Path.Combine(directory, "mod-load-status.json");
            RejectSymlinks(documents, path);
            Directory.CreateDirectory(directory);
            temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            status["updatedAtUtc"] = DateTimeOffset.UtcNow.ToString("O");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream))
            {
                writer.Write(status.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception e) { PatchHelper.Log($"Could not write mod-load-status.json: {e}"); }
        finally
        {
            if (temporary != null)
                try { File.Delete(temporary); } catch (Exception e) { PatchHelper.Log($"Could not remove resource status temporary file: {e.Message}"); }
        }
    }
}
