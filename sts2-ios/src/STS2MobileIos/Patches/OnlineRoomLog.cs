using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Godot;
using MegaCrit.Sts2.Core.Entities.Multiplayer;

namespace STS2MobileIos.Patches;

/// <summary>
/// 联机组件日志（三端规范 §5.2）：统一前缀 [OnlineRoom] 写进游戏日志，同时按启动器同行格式
/// 追加到 user://Launcher/online-game.log（iPad 的 Launcher 目录首字母大写，与 pending-action 同目录），
/// 让启动器的「日志」页不解析整份 godot.log 也能看到联机报错。
/// </summary>
public static class OnlineRoomLog
{
    private const long MaxBytes = 2 * 1024 * 1024;
    private static readonly object Gate = new();
    private static readonly Regex Secret = new(
        "(\"?(?:auth\\.)?(?:token|password|passwd|pwd|api[_-]?key|apikey|secret|refresh_?token|access_?token|authorization)\"?\\s*[:=]\\s*\"?)([^\"\\s,}&]+)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex Bearer = new("(Bearer\\s+)[^\\s\",}]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string LogPath => Path.Combine(OS.GetUserDataDir(), "Launcher", "online-game.log");

    public static void Info(string message) => Write('I', message, null);
    public static void Warn(string message, Exception error = null) => Write('W', message, error);
    public static void Error(string message, Exception error = null) => Write('E', message, error);

    /// <summary>与启动器相同的行格式：时间 级别 [online] 消息 | 异常类型: 消息，堆栈缩进。</summary>
    public static string Format(DateTimeOffset time, char level, string message, Exception error)
    {
        var line = new StringBuilder();
        line.Append(time.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture))
            .Append(' ').Append(level).Append(" [online] ").Append(Redact(message));
        if (error != null)
        {
            line.Append(" | ").Append(error.GetType().Name).Append(": ").Append(Redact(error.Message));
            foreach (var frame in (error.StackTrace ?? string.Empty).Split('\n'))
                if (!string.IsNullOrWhiteSpace(frame)) line.Append("\n    ").Append(frame.Trim());
        }
        return line.ToString();
    }

    public static string Redact(string text) =>
        string.IsNullOrEmpty(text) ? text ?? string.Empty : Secret.Replace(Bearer.Replace(text, "$1***"), "$1***");

    private static void Write(char level, string message, Exception error)
    {
        PatchHelper.Log("[OnlineRoom] " + Redact(message) + (error != null ? " | " + Redact(error.ToString()) : string.Empty));
        try
        {
            lock (Gate)
            {
                var path = LogPath;
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxBytes)
                    File.Move(path, Path.Combine(info.DirectoryName!, "online-game.1.log"), overwrite: true);
                File.AppendAllText(path, Format(DateTimeOffset.Now, level, message, error) + "\n", Encoding.UTF8);
            }
        }
        catch (Exception e)
        {
            // 日志文件写不进去时只能留在 godot.log，不能让日志反过来打断联机流程。
            PatchHelper.Log($"[OnlineRoom] online-game.log write failed: {e.Message}");
        }
    }

    // NErrorPopup.Create(NetErrorInfo) prefix：原版握手失败、断线、房间满等都会走这里，记下原版错误码原文。
    public static void NetErrorPopupPrefix(NetErrorInfo info)
    {
        try { Error($"联机错误弹窗: {info.GetReason()} | {info}"); }
        catch (Exception e) { PatchHelper.Log($"[OnlineRoom] could not describe net error: {e.Message}"); }
    }
}
