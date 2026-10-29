using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Godot;
using MegaCrit.Sts2.Core.Multiplayer;
using FileAccess = System.IO.FileAccess;

namespace STS2MobileIos.Patches;

/// <summary>Admission gate for the single statically adapted More Silent build.</summary>
public static class CompiledModPatches
{
    public const string Feature = "more-silent-animations-v0.1.33";
    public const string SourceSha256 = "1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41";
    public const string BuildId = "sts2-ios-v0.111.0-more-silent-0.1.33-r1";
    public const string ModId = "MoreSilentAnimations";

    private static int _state; // 0=cold, 1=initializing, 2=frozen
    private static bool _enabled;

    /// <summary>Cold-start gate; initialization runs at most once per process.</summary>
    public static bool IsMoreSilentEnabled()
    {
        if (Volatile.Read(ref _state) == 2) return _enabled;
        var entry = NewEntry(requested: false);
        var documents = new string[1];
        var enabled = InitializeOnce(ref _state,
            () => _enabled = RunGate(entry, documents),
            e =>
        {
            _enabled = false;
            entry["status"] = "failed";
            entry["error"] = SafeError(e);
            TryLog($"Compiled More Silent gate failed closed: {e}");
            if (documents[0] != null) WriteStatus(documents[0], entry);
        }, out var owner);
        if (!owner) return Volatile.Read(ref _state) == 2 && _enabled;
        return enabled;
    }

    private static bool RunGate(JsonObject entry, string[] documents)
    {
        documents[0] = Path.GetFullPath(OS.GetUserDataDir());
        if (!HasMoreSilentSupport())
            throw new InvalidDataException("This executable has no More Silent adapter support.");
        var capability = ReadCapability();
        if (!TryReadRequest(documents[0], capability, out var requested, out var id, out var error))
            throw new InvalidDataException(error);
        entry["id"] = id;
        entry["requested"] = requested;
        if (!requested)
        {
            entry["status"] = "disabled";
            WriteStatus(documents[0], entry);
            return false;
        }

        // Source implementation intentionally stays empty. The signed app's
        // offline-adapted gate DLL replaces this method with a direct static call.
        InitializeMoreSilent();
        entry["status"] = "loaded";
        WriteStatus(documents[0], entry);
        return true;
    }

    /// <summary>Call from the game startup prefix to initialize before gameplay.</summary>
    public static void InitializePrefix() => _ = IsMoreSilentEnabled();

    /// <summary>Source-tree support stays closed; the signed adapter build patches this stub.</summary>
    public static bool HasMoreSilentSupport() => false;

    /// <summary>Source-tree initializer stays inert; the signed adapter build patches this stub.</summary>
    public static void InitializeMoreSilent() { }

    /// <summary>Add the fixed build fingerprint without changing any vanilla handshake fields.</summary>
    public static void AugmentPeerVersion(ref PeerVersionInfo result)
    {
        try
        {
            if (!IsMoreSilentEnabled()) return;
            result.gameplayAffectingMods = AppendMoreSilentFingerprint(result.gameplayAffectingMods);
        }
        catch (Exception e) { TryLog($"Could not augment compiled MOD peer version: {e}"); }
    }

    internal static List<string> AppendMoreSilentFingerprint(IEnumerable<string> existing)
    {
        var mods = existing == null ? new List<string>() : new List<string>(existing);
        var fingerprint = $"ios-compiled-mod-v1:{Feature}:{SourceSha256}";
        if (!mods.Contains(fingerprint, StringComparer.Ordinal)) mods.Add(fingerprint);
        return mods;
    }

    // Pure admission helper shared with the synthetic private tests. It never loads
    // assemblies and accepts only one exact capability and one exact request.
    internal static bool EvaluateAdmission(bool support, JsonObject capability, JsonObject config,
        out bool requested, out string id, out string error)
    {
        requested = false;
        id = string.Empty;
        error = string.Empty;
        try
        {
            if (!support) throw new InvalidDataException("Adapter support is disabled.");
            ValidateCapability(capability);
            if (config["schemaVersion"]?.GetValue<int>() != 1)
                throw new InvalidDataException("Unsupported launcher config schema.");
            if (config["compiledMods"] is not JsonArray requests)
                throw new InvalidDataException("compiledMods must be an array.");

            var relevant = new List<JsonObject>();
            foreach (var item in requests)
            {
                if (item is not JsonObject request)
                    throw new InvalidDataException("compiledMods entries must be objects.");
                var modId = RequiredString(request, "modId");
                var feature = RequiredString(request, "feature");
                var sourceHash = RequiredString(request, "sourceSha256");
                var buildId = RequiredString(request, "buildId");
                var contentId = RequiredString(request, "id");
                if (!IsHex(contentId, 64)) throw new InvalidDataException("Invalid compiled MOD content ID.");
                if (modId == ModId || feature == Feature) relevant.Add(request);
            }

            if (relevant.Count == 0) return true;
            if (relevant.Count != 1)
                throw new InvalidDataException("Duplicate More Silent requests are forbidden.");

            var only = relevant[0];
            id = RequiredString(only, "id");
            if (RequiredString(only, "modId") != ModId || RequiredString(only, "feature") != Feature ||
                !string.Equals(RequiredString(only, "sourceSha256"), SourceSha256, StringComparison.OrdinalIgnoreCase) ||
                RequiredString(only, "buildId") != BuildId)
                throw new InvalidDataException("Compiled MOD request does not match this signed build.");
            requested = true;
            return true;
        }
        catch (Exception e)
        {
            error = SafeError(e);
            return false;
        }
    }

    // Reusable state transition makes once-only, fail-closed behavior testable
    // without exposing any production injection point.
    internal static bool InitializeOnce(ref int state, Func<bool> initialize, Action<Exception> onError, out bool owner)
    {
        owner = Interlocked.CompareExchange(ref state, 1, 0) == 0;
        if (!owner) return false;
        try
        {
            var result = initialize();
            Volatile.Write(ref state, 2);
            return result;
        }
        catch (Exception e)
        {
            try { onError?.Invoke(e); } catch { }
            Volatile.Write(ref state, 2);
            return false;
        }
    }

    private static JsonObject NewEntry(bool requested) => new()
    {
        ["id"] = string.Empty, ["modId"] = ModId, ["feature"] = Feature,
        ["sourceSha256"] = SourceSha256, ["requested"] = requested,
        ["status"] = "failed", ["error"] = string.Empty,
    };

    private static JsonObject ReadCapability()
    {
        var directory = Path.GetFullPath(AppContext.BaseDirectory);
        var path = Path.Combine(directory, "compiled-mods.json");
        RejectSymlinks(directory, path);
        if (!File.Exists(path)) throw new FileNotFoundException("Signed compiled-mods.json is missing.", path);
        var capability = ParseObject(File.ReadAllText(path), "compiled-mods.json must be an object.");
        ValidateCapability(capability, directory);
        return capability;
    }

    private static void ValidateCapability(JsonObject capability, string directory = null)
    {
        if (capability["schemaVersion"]?.GetValue<int>() != 1 || RequiredString(capability, "buildId") != BuildId)
            throw new InvalidDataException("Signed compiled MOD capability does not match this build.");
        if (capability["mods"] is not JsonArray mods)
            throw new InvalidDataException("Capability mods must be an array.");
        var relevant = new List<JsonObject>();
        foreach (var item in mods)
        {
            if (item is not JsonObject mod) throw new InvalidDataException("Capability MOD entries must be objects.");
            var modId = RequiredString(mod, "modId");
            var feature = RequiredString(mod, "feature");
            var sourceHash = RequiredString(mod, "sourceSha256");
            _ = RequiredString(mod, "gameVersion");
            _ = RequiredString(mod, "version");
            if (mod["files"] is not JsonArray files) throw new InvalidDataException("Capability files must be an array.");
            var seenPaths = new HashSet<string>(StringComparer.Ordinal);
            foreach (var fileNode in files)
            {
                if (fileNode is not JsonObject fileEntry)
                    throw new InvalidDataException("Capability file entries must be objects.");
                var file = RequiredString(fileEntry, "path");
                var fileHash = RequiredString(fileEntry, "sha256");
                if (!IsSafeRelativePath(file) || !IsHex(fileHash, 64))
                    throw new InvalidDataException("Capability contains an invalid file path.");
                if (fileEntry["size"] is not JsonValue sizeNode ||
                    !sizeNode.TryGetValue<long>(out var fileSize) || fileSize < 0)
                    throw new InvalidDataException("Capability file size must be a nonnegative integer.");
                if (!seenPaths.Add(file))
                    throw new InvalidDataException("Capability contains a duplicate file path.");
                if (directory != null)
                {
                    var filePath = Path.GetFullPath(Path.Combine(directory, file));
                    if (!filePath.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                        throw new InvalidDataException("Capability file escapes the app executable directory.");
                    RejectSymlinks(directory, filePath);
                    if (!File.Exists(filePath)) throw new FileNotFoundException("Signed compiled MOD file is missing.", filePath);
                }
            }
            if (modId == ModId || feature == Feature) relevant.Add(mod);
        }
        if (relevant.Count != 1) throw new InvalidDataException("Capability must contain exactly one More Silent entry.");
        var exact = relevant[0];
        if (RequiredString(exact, "modId") != ModId || RequiredString(exact, "feature") != Feature ||
            !string.Equals(RequiredString(exact, "sourceSha256"), SourceSha256, StringComparison.OrdinalIgnoreCase) ||
            RequiredString(exact, "gameVersion") != "v0.111.0" || RequiredString(exact, "version") != "0.1.33")
            throw new InvalidDataException("Signed capability does not match the fixed More Silent source.");
    }

    internal static JsonObject ParseObject(string json, string message) =>
        JsonNode.Parse(json) as JsonObject ?? throw new InvalidDataException(message);

    private static bool TryReadRequest(string documents, JsonObject capability, out bool requested, out string id, out string error)
    {
        requested = false;
        id = string.Empty;
        error = string.Empty;
        try
        {
            var path = Path.Combine(documents, "Launcher", "config.json");
            RejectSymlinks(documents, path);
            if (!File.Exists(path))
            {
                // A valid capability with no launcher intent is simply disabled.
                requested = false;
                return true;
            }
            var config = ParseObject(File.ReadAllText(path), "Launcher config must be an object.");
            return EvaluateAdmission(HasMoreSilentSupport(), capability, config, out requested, out id, out error);
        }
        catch (Exception e) { error = SafeError(e); return false; }
    }

    private static void WriteStatus(string documents, JsonObject entry)
    {
        string temporary = null;
        try
        {
            var directory = Path.Combine(documents, "Launcher");
            var path = Path.Combine(directory, "compiled-mod-load-status.json");
            RejectSymlinks(documents, path);
            Directory.CreateDirectory(directory);
            RejectSymlinks(documents, path);
            var status = new JsonObject
            {
                ["schemaVersion"] = 1, ["buildId"] = BuildId, ["completed"] = true,
                ["entries"] = new JsonArray(entry.DeepClone()),
            };
            temporary = Path.Combine(directory, ".compiled-mod-load-status-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                writer.Write(status.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            RejectSymlinks(documents, path);
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception e) { TryLog($"Could not write compiled MOD status: {e}"); }
        finally
        {
            if (temporary != null)
                try { File.Delete(temporary); } catch (Exception e) { TryLog($"Could not clean compiled MOD status temporary file: {e.Message}"); }
        }
    }

    private static string RequiredString(JsonObject value, string key)
    {
        if (value[key] is not JsonValue node || !node.TryGetValue<string>(out var text) || string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException($"{key} must be a nonempty string.");
        return text;
    }

    private static bool IsHex(string value, int length) => value.Length == length && value.All(char.IsAsciiHexDigit);

    private static bool IsSafeRelativePath(string path) => !string.IsNullOrWhiteSpace(path) &&
        !Path.IsPathRooted(path) && !path.Contains('\\') && path.IndexOf('\0') < 0 &&
        path.Split('/').All(part => part.Length > 0 && part != "." && part != "..");

    private static void RejectSymlinks(string root, string path)
    {
        root = Path.GetFullPath(root);
        path = Path.GetFullPath(path);
        var relative = Path.GetRelativePath(root, path);
        if (relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new InvalidDataException("Path escapes its trusted root.");
        var volume = Path.GetPathRoot(root);
        CheckNotLink(volume);
        var rootRelative = Path.GetRelativePath(volume, root);
        var current = volume;
        foreach (var component in rootRelative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries)
                     .Concat(relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries)))
        {
            current = Path.Combine(current, component);
            CheckNotLink(current);
        }
    }

    private static void CheckNotLink(string path)
    {
        if (new FileInfo(path).LinkTarget != null || new DirectoryInfo(path).LinkTarget != null ||
            (File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Symlinks are forbidden in compiled MOD paths.");
    }

    private static string SafeError(Exception e) => string.IsNullOrWhiteSpace(e.Message) ? e.GetType().Name : e.Message;

    private static void TryLog(string message)
    {
        try { PatchHelper.Log(message); } catch { }
    }
}
