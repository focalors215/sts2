namespace STS2MobileIos.Patches;

/// <summary>
/// 三端规范 §3.4（2026-11-09 定稿）：ENet 房主 NetId 原版固定为 1，加入方 NetId = 本机 playerId。
/// 多人存档 Players[].NetId 里房主那位永远是 1。判定本机在存档里的身份时必须先查 playerId 再查 1，
/// 因为加入方本地存档里也有原房主的 1；只查 1 会让原加入方顶替房主。纯逻辑，便于离线测试。
/// </summary>
public static class MultiplayerIdentity
{
    public const ulong HostNetId = 1;

    public enum Role { Joiner, Host, Mismatch }

    public const string MismatchMessage = "这个多人存档不属于当前玩家 ID。请恢复创建存档时的玩家 ID，存档已保留未改动。";
    public const string JoinerCannotHostMessage = "这个多人存档里你是加入方，只能由原房主开房续局。请让原房主创建房间后加入。";

    public static Role Resolve(IEnumerable<ulong> saveNetIds, ulong playerId, out ulong identity)
    {
        var ids = saveNetIds as ICollection<ulong> ?? saveNetIds.ToList();
        if (playerId > HostNetId && ids.Contains(playerId)) { identity = playerId; return Role.Joiner; }
        if (ids.Contains(HostNetId)) { identity = HostNetId; return Role.Host; }
        identity = 0;
        return Role.Mismatch;
    }

    /// <summary>playerId 合法范围 [2, 2^63-1]；0、1 与超范围值都要重新生成。</summary>
    public static bool IsValidPlayerId(ulong value) => value > HostNetId && value <= long.MaxValue;
}
