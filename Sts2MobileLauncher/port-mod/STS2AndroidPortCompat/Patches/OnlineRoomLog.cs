using System;
using System.IO;
using System.Text;
using STS2Mobile.Android;

namespace STS2Mobile.Patches;

/// <summary>
/// [OnlineRoom] logging shared by the online room / LAN identity patches.
/// Every line goes to the game log (PatchHelper.Log) and is appended to
/// DataDir/launcher/online-game.log in the cross-platform launcher format
/// (doc/architecture/cross-platform-parity.md §5.1/§5.2):
/// <c>2026-11-09T12:34:56.789+08:00 E [online] message | Type: text</c> plus an
/// indented stack trace. The launcher shows and exports this file.
/// </summary>
public static class OnlineRoomLog
{
    private const long MaxBytes = 2L * 1024 * 1024;
    private static readonly object Gate = new();

    internal static string LogPath => Path.Combine(AppPaths.DataDir, "launcher", "online-game.log");

    public static void Info(string message) => Write('I', message, null);

    public static void Warn(string message, Exception exception = null) => Write('W', message, exception);

    public static void Error(string message, Exception exception = null) => Write('E', message, exception);

    public static void Write(char level, string message, Exception exception)
    {
        PatchHelper.Log($"[OnlineRoom] {level} {message}" + (exception == null ? string.Empty : $" | {exception}"));
        try
        {
            AppendToFile(LogPath, OnlineRoomProtocol.FormatLogLine(DateTimeOffset.Now, level, "online", message, exception));
        }
        catch (Exception fileError)
        {
            // The game log line above already carries the message; only the side file failed.
            PatchHelper.Log($"[OnlineRoom] Could not append online-game.log: {fileError.Message}");
        }
    }

    internal static void AppendToFile(string path, string line)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var info = new FileInfo(path);
            if (info.Exists && info.Length > MaxBytes)
            {
                var backup = Path.Combine(info.DirectoryName!, Path.GetFileNameWithoutExtension(path) + ".1.log");
                File.Copy(path, backup, overwrite: true);
                File.Delete(path);
            }
            File.AppendAllText(path, line, new UTF8Encoding(false));
        }
    }
}
