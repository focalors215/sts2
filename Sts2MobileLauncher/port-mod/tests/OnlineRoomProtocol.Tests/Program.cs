using System;
using System.Text.RegularExpressions;
using STS2Mobile.Patches;
using static STS2Mobile.Patches.OnlineRoomProtocol;

// Regression for doc/architecture/cross-platform-parity.md §3.3 (pending-action.json),
// §3.4 (multiplayer save identity) and §5.1 (log line format). No game code involved.
internal static class Program
{
    private const long Now = 1762650000;

    private static int Main()
    {
        PendingActions();
        SaveIdentity();
        LogLines();
        Console.WriteLine("OnlineRoomProtocol tests passed.");
        return 0;
    }

    private static void PendingActions()
    {
        var join = ParsePendingAction("{\"v\":1,\"type\":\"join\",\"created\":1762649990,\"online\":true,\"host\":\"frp.example.com\",\"port\":33774,\"nickname\":\" 喵喵零 \",\"playerId\":\"1234567890123\"}", Now, out var error, out var warning);
        Check(join != null && error == null && warning == null, $"valid join rejected: {error}");
        Check(join.Type == "join" && join.Host == "frp.example.com" && join.Port == 33774, "join fields");
        Check(join.Nickname == "喵喵零" && join.PlayerId == 1234567890123UL && join.Online, "nickname/playerId");

        var numericId = ParsePendingAction("{\"type\":\"host\",\"created\":1762650000,\"playerId\":987654321}", Now, out error, out _);
        Check(numericId?.PlayerId == 987654321UL, "numeric playerId");

        var hostId = ParsePendingAction("{\"type\":\"host\",\"created\":1762650000,\"playerId\":\"1\"}", Now, out error, out _);
        Check(hostId != null && hostId.PlayerId == 0, "playerId 1 is reserved for the host and must be ignored");

        Check(ParsePendingAction("{\"type\":\"host\",\"created\":1762649000}", Now, out error, out _) == null && error.Contains("过期"), "action older than 600 s must expire");
        Check(ParsePendingAction("{\"type\":\"host\",\"created\":1762649400}", Now, out error, out _) != null, "exactly 600 s is still valid");

        var legacy = ParsePendingAction("{\"type\":\"host\"}", Now, out error, out warning);
        Check(legacy != null && warning != null, "missing created is accepted with a warning");

        Check(ParsePendingAction("{\"type\":\"spectate\",\"created\":1762650000}", Now, out error, out _) == null && error.Contains("spectate"), "unknown type");
        Check(ParsePendingAction("not json", Now, out error, out _) == null && error != null, "bad JSON");
        Check(ParsePendingAction("[1]", Now, out error, out _) == null, "non-object JSON");
        Check(ParsePendingAction("{\"type\":\"join\",\"created\":1762650000,\"host\":\"\",\"port\":33774}", Now, out error, out _) == null, "empty host");
        Check(ParsePendingAction("{\"type\":\"join\",\"created\":1762650000,\"host\":\"a b\",\"port\":33774}", Now, out error, out _) == null, "host with whitespace");
        Check(ParsePendingAction("{\"type\":\"join\",\"created\":1762650000,\"host\":\"h\",\"port\":70000}", Now, out error, out _) == null, "port out of range");
        Check(ParsePendingAction("{\"type\":\"host\",\"created\":1762650000,\"port\":0}", Now, out error, out _) != null, "host ignores host/port");
    }

    private static void SaveIdentity()
    {
        const ulong me = 4242424242UL;
        Check(ResolveSaveRole(new ulong[] { 1, me }, me, out var id) == SaveRole.Joiner && id == me, "joiner copy contains both 1 and me: must resolve to me");
        Check(ResolveSaveRole(new ulong[] { 1, 777 }, me, out id) == SaveRole.Host && id == 1, "host copy: resolve to 1");
        Check(ResolveSaveRole(new ulong[] { 1 }, me, out id) == SaveRole.Host && id == 1, "solo host save");
        Check(ResolveSaveRole(new ulong[] { 777, 888 }, me, out id) == SaveRole.Mismatch && id == 0, "foreign save");
        Check(ResolveSaveRole(new ulong[] { 1, 777 }, 1, out id) == SaveRole.Host, "invalid stable id 1 never counts as joiner");
        Check(!IsValidPlayerId(0) && !IsValidPlayerId(1) && IsValidPlayerId(2) && IsValidPlayerId((ulong)long.MaxValue) && !IsValidPlayerId((ulong)long.MaxValue + 1), "playerId range");
    }

    private static void LogLines()
    {
        var time = new DateTimeOffset(2026, 11, 9, 12, 34, 56, 789, TimeSpan.FromHours(8));
        var plain = FormatLogLine(time, 'I', "online", "读取联机指令\nsecond", null);
        Check(plain == "2026-11-09T12:34:56.789+08:00 I [online] 读取联机指令 second\n", $"plain line: {plain}");
        Exception thrown;
        try { throw new InvalidOperationException("boom", new FormatException("inner")); }
        catch (Exception e) { thrown = e; }
        var withError = FormatLogLine(time, 'E', "online", "加入失败", thrown);
        var lines = withError.TrimEnd('\n').Split('\n');
        Check(Regex.IsMatch(lines[0], @"^2026-11-09T12:34:56\.789\+08:00 E \[online\] 加入失败 \| System\.InvalidOperationException: boom$"), $"error head: {lines[0]}");
        Check(lines.Length >= 3 && lines[1].StartsWith("    at ", StringComparison.Ordinal), "stack frames are indented");
        Check(withError.Contains("    caused by System.FormatException: inner"), "inner exception");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException("FAILED: " + message);
    }
}
