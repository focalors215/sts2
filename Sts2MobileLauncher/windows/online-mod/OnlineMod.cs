using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Helpers;
using MegaCrit.Sts2.Core.Modding;
using MegaCrit.Sts2.Core.Multiplayer;
using MegaCrit.Sts2.Core.Multiplayer.Connection;
#if !STS2_TARGET_1071
using MegaCrit.Sts2.Core.Multiplayer.Game;
#endif
using MegaCrit.Sts2.Core.Nodes.CommonUi;
using MegaCrit.Sts2.Core.Nodes.Screens.CharacterSelect;
using MegaCrit.Sts2.Core.Nodes.Screens.CustomRun;
using MegaCrit.Sts2.Core.Nodes.Screens.DailyRun;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;
using MegaCrit.Sts2.Core.Platform.Null;
using MegaCrit.Sts2.Core.Runs;
using MegaCrit.Sts2.Core.Saves;

namespace STS2CottageOnline;

/// <summary>
/// Windows 小屋启动器的联机组件。启动器在 user://launcher/pending-action.json 写一次性指令
/// （与 Android / iPad 的 RemoteRoomPatches 同一协议，见 doc/architecture/cross-platform-parity.md §3.3）：
/// "host" 在本机 UDP 33771 用游戏自带的 ENet 开房（在线房间由启动器的 frp 映射到服务器），
/// "join" 用原版 JoinFlow 连到房间地址。不改消息、序列化、版本或 ModelDb 校验；Steam 好友联机照常可用。
/// 按游戏版本分别构建：GameVersion=v0.107.1 定义 STS2_TARGET_1071，其余为 v0.111.0。
/// 日志统一前缀 [OnlineRoom] 写进游戏日志，并追加到 user://launcher/online-game.log（规范 §5.2）。
/// </summary>
[ModInitializer(nameof(Initialize))]
public static class OnlineMod
{
    public const string ModId = "STS2CottageOnline";
    private const ushort GamePort = 33771; // NMultiplayerHostSubmenu 原版 ENet 端口，联机小屋各端相同
    private const int MaxPlayers = 4;
    private const ulong HostNetId = 1; // NullPlatformUtilStrategy.LocalPlayerId，ENet 房主身份
    private const long MaxActionAgeSeconds = 600;
    private const long MaxLogBytes = 2 * 1024 * 1024;
#if STS2_TARGET_1071
    public const string BuiltForGameVersion = "v0.107.1";
#else
    public const string BuiltForGameVersion = "v0.111.0";
#endif

    private static bool _consumed;
    private static ulong _localNetId;
    private static string _nickname;
    // 启动器的联机指令执行期间（开房 / 加入及之后的这局联机），原版错误弹窗的内容也写进联机日志。
    private static bool _onlineSession;
    private static readonly object LogLock = new();

    private static string ActionPath => ProjectSettings.GlobalizePath("user://launcher/pending-action.json");
    private static string OnlineLogPath => ProjectSettings.GlobalizePath("user://launcher/online-game.log");

    public static void Initialize()
    {
        var harmony = new Harmony("sts2.cottage.online");
        Patch(harmony, typeof(NMainMenu), "_Ready", postfix: nameof(MainMenuReadyPostfix));
        Patch(harmony, typeof(NullPlatformUtilStrategy), "GetPlayerName", prefix: nameof(NullGetPlayerNamePrefix));
        Patch(harmony, typeof(UserDataPathProvider), "set_IsRunningModded", prefix: nameof(SetIsRunningModdedPrefix));
        PatchErrorPopups(harmony);
        Log('I', $"loaded (built for {BuiltForGameVersion})");
    }

    // 原版握手失败、断线等都通过 NErrorPopup.Create 弹窗；联机会话期间把弹窗内容原文记进联机日志。
    private static void PatchErrorPopups(Harmony harmony)
    {
        try
        {
            var postfix = new HarmonyMethod(typeof(OnlineMod), nameof(ErrorPopupPostfix));
            foreach (var method in typeof(NErrorPopup).GetMethods(BindingFlags.Public | BindingFlags.Static).Where(m => m.Name == "Create"))
                harmony.Patch(method, postfix: postfix);
        }
        catch (Exception e)
        {
            Log('W', $"patch NErrorPopup.Create failed: {e.Message}");
        }
    }

    public static void ErrorPopupPostfix(object[] __args)
    {
        if (!_onlineSession)
            return;
        try
        {
            var parts = (__args ?? Array.Empty<object>()).Where(a => a != null && a is not bool).Select(DescribeArg);
            Log('W', $"game error popup: {string.Join(" | ", parts)}");
        }
        catch (Exception e)
        {
            Log('D', $"could not describe error popup: {e.Message}");
        }
    }

    private static string DescribeArg(object arg)
    {
        var text = arg.ToString();
        var type = arg.GetType();
        if (!type.IsValueType || type.IsPrimitive || type.IsEnum)
            return text;
        // 结构体（如原版网络错误信息）把公开字段 / 属性也写出来，便于排查握手失败原因。
        var members = type.GetFields(BindingFlags.Public | BindingFlags.Instance).Select(f => $"{f.Name}={f.GetValue(arg)}")
            .Concat(type.GetProperties(BindingFlags.Public | BindingFlags.Instance).Where(p => p.GetIndexParameters().Length == 0)
                .Select(p => { try { return $"{p.Name}={p.GetValue(arg)}"; } catch { return null; } }))
            .Where(x => x != null);
        return $"{type.Name}{{{string.Join(", ", members)}}}";
    }

    private static void Patch(Harmony harmony, Type type, string method, string prefix = null, string postfix = null)
    {
        try
        {
            var target = AccessTools.Method(type, method);
            if (target == null)
            {
                Log('W', $"skip {type.Name}.{method}: not found");
                return;
            }
            harmony.Patch(target,
                prefix: prefix == null ? null : new HarmonyMethod(typeof(OnlineMod), prefix),
                postfix: postfix == null ? null : new HarmonyMethod(typeof(OnlineMod), postfix));
        }
        catch (Exception e)
        {
            Log('W', $"patch {type.Name}.{method} failed: {e.Message}");
        }
    }

    /// <summary>
    /// 游戏日志用 [OnlineRoom] 前缀；同时按启动器统一行格式追加到 user://launcher/online-game.log
    /// （超过 2 MiB 时转存为 online-game.1.log）。
    /// </summary>
    private static void Log(char level, string message)
    {
        var text = $"[OnlineRoom] {message}";
        if (level == 'E')
            GD.PrintErr(text);
        else
            GD.Print(text);
        try
        {
            var line = $"{DateTimeOffset.Now:yyyy-MM-dd'T'HH:mm:ss.fffzzz} {level} [online] {message.Replace("\n", "\n    ")}\n";
            lock (LogLock)
            {
                var file = OnlineLogPath;
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                var info = new FileInfo(file);
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    var rotated = Path.Combine(Path.GetDirectoryName(file)!, "online-game.1.log");
                    File.Delete(rotated);
                    File.Move(file, rotated);
                }
                File.AppendAllText(file, line, new UTF8Encoding(false));
            }
        }
        catch (Exception e)
        {
            GD.PrintErr($"[OnlineRoom] could not write online-game.log: {e.Message}");
        }
    }

    // 原版只要加载了任何 MOD 就把存档切到 modded/ 目录。本组件不影响玩法，
    // 只有它一个 MOD 时保持原存档位置，免得装上联机组件后“存档不见了”。
    public static void SetIsRunningModdedPrefix(ref bool value)
    {
        if (!value)
            return;
        try
        {
            var active = ModManager.Mods.Where(m => m.state is ModLoadState.Loaded or ModLoadState.Failed).ToList();
            if (active.Count > 0 && active.All(m => m.manifest?.id == ModId))
                value = false;
        }
        catch (Exception e)
        {
            Log('W', $"modded save dir check failed: {e.Message}");
        }
    }

    public static bool NullGetPlayerNamePrefix(ulong playerId, ref string __result)
    {
        if (_localNetId != 0 && playerId == _localNetId && !string.IsNullOrWhiteSpace(_nickname))
            __result = _nickname;
        else if (playerId == HostNetId)
            __result = "房主";
        else
            __result = $"玩家 {playerId % 10000UL:0000}";
        return false;
    }

    public static void MainMenuReadyPostfix(NMainMenu __instance)
    {
        if (_consumed || __instance == null)
            return;
        _consumed = true;
        var (action, error) = TakeAction();
        if (action != null || error != null)
            TaskHelper.RunSafely(Run(__instance, action, error));
    }

    // 读一次就删，回到主菜单不会重复执行。过期指令（启动器异常退出留下的）丢弃并写日志；
    // 解析失败、未知 type 返回错误文案，由 Run 在主菜单弹窗提示（规范 §3.3）。
    private static (JsonObject action, string error) TakeAction()
    {
        string text;
        try
        {
            if (!File.Exists(ActionPath))
                return (null, null);
            text = File.ReadAllText(ActionPath);
        }
        catch (Exception e)
        {
            Log('E', $"could not read pending action {ActionPath}: {e}");
            TryDeleteAction();
            return (null, "读取启动器的联机指令失败，请回到启动器重新开房或加入。");
        }
        TryDeleteAction();
        JsonObject action;
        try
        {
            action = JsonNode.Parse(text) as JsonObject;
        }
        catch (Exception e)
        {
            Log('E', $"pending action is not valid JSON: {e.Message}");
            return (null, "启动器的联机指令格式错误，请回到启动器重新开房或加入。");
        }
        if (action == null)
        {
            Log('E', "pending action is not a JSON object");
            return (null, "启动器的联机指令格式错误，请回到启动器重新开房或加入。");
        }
        var created = ReadLong(action, "created");
        var age = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - created;
        if (Math.Abs(age) > MaxActionAgeSeconds)
        {
            Log('W', $"discarded stale pending action type={ReadString(action, "type")} created={created} age={age}s (max {MaxActionAgeSeconds}s)");
            return (null, null);
        }
        var version = ReadLong(action, "v");
        if (version != 1)
            Log('W', $"pending action version {version} (expected 1), trying anyway");
        Log('I', $"took pending action type={ReadString(action, "type")} online={ReadBool(action, "online")} age={age}s");
        return (action, null);
    }

    private static void TryDeleteAction()
    {
        try { File.Delete(ActionPath); }
        catch (Exception e) { Log('W', $"could not delete pending action: {e.Message}"); }
    }

    private static string ReadString(JsonObject action, string key)
    {
        try { return action[key]?.GetValue<string>(); }
        catch { return action[key]?.ToJsonString(); }
    }

    private static long ReadLong(JsonObject action, string key)
    {
        try { return action[key]?.GetValue<long>() ?? 0; }
        catch
        {
            return long.TryParse(ReadString(action, key), out var value) ? value : 0;
        }
    }

    private static bool ReadBool(JsonObject action, string key)
    {
        try { return action[key]?.GetValue<bool>() ?? false; }
        catch { return false; }
    }

    private static async Task Run(NMainMenu menu, JsonObject action, string takeError)
    {
        // 等主菜单完成第一次布局与更新说明。
        await menu.ToSignal(menu.GetTree().CreateTimer(0.6), Godot.Timer.SignalName.Timeout);
        if (!GodotObject.IsInstanceValid(menu) || !menu.IsInsideTree())
        {
            Log('W', "main menu left the tree before the pending action ran");
            return;
        }
        if (takeError != null)
        {
            ShowInfo("联机指令无效", takeError);
            return;
        }
        var type = ReadString(action, "type");
        _nickname = ReadString(action, "nickname");
        var online = ReadBool(action, "online");
        _onlineSession = true;
        try
        {
            if (type == "host")
                Host(menu, online, action);
            else if (type == "join")
                await Join(menu, action);
            else
            {
                Log('E', $"unknown pending action type '{type}'");
                ShowInfo("联机指令无效", $"未知的联机指令类型「{type}」，请更新启动器后重试。");
            }
        }
        catch (Exception e)
        {
            Log('E', $"{type} failed: {e}");
            ShowInfo(type == "host" ? "开房失败" : "加入失败", e.Message);
        }
    }

    // 续局身份（规范 §3.4）：房主 NetId 恒为 1，加入方为各自 playerId。存档含本机 playerId → 本机是那局的
    // 加入方，不能开房续局；否则含 1 → 本机是房主；都不含 → 身份不匹配。不匹配时不调原版 canonicalization，
    // 避免存档被当成损坏文件改名。
    private static void Host(NMainMenu menu, bool online, JsonObject action)
    {
        _localNetId = HostNetId;
        ulong.TryParse(ReadString(action, "playerId"), out var playerId);
        var submenu = menu.OpenMultiplayerSubmenu();
        var stack = (NSubmenuStack)AccessTools.Field(typeof(NSubmenu), "_stack").GetValue(submenu);
        var overlay = AccessTools.Field(typeof(NMultiplayerSubmenu), "_loadingOverlay")?.GetValue(submenu) as Control;
        SerializableRun run = null;
        if (SaveManager.Instance.HasMultiplayerRunSave)
        {
            // 与原版“继续”相同：房间续上这一局。先确认存档里有 ENet 房主身份，避免
            // 原版 canonicalization 因身份不符把存档当成损坏文件改名。
            var ids = RawSavePlayerIds();
            if (playerId > HostNetId && ids.Contains(playerId))
            {
                Log('W', $"续局身份为加入方，拒绝开房: save={string.Join(",", ids)} local={playerId}");
                ShowInfo("无法开房续局", "这个多人存档里你是加入方，只能由原房主开房续局。请让原房主创建房间后加入。");
                return;
            }
            if (!ids.Contains(HostNetId))
            {
                Log('W', $"续局身份不匹配: save={string.Join(",", ids)} local={playerId}");
                ShowInfo("无法开房续局", "这个多人存档不属于当前玩家 ID。请恢复创建存档时的玩家 ID，存档已保留未改动。");
                return;
            }
            var save = SaveManager.Instance.LoadAndCanonicalizeMultiplayerRunSave(HostNetId);
            if (!save.Success || save.SaveData == null)
            {
                Log('E', "LoadAndCanonicalizeMultiplayerRunSave failed");
                ShowInfo("无法继续多人存档", "多人存档读取失败。可在游戏多人菜单中放弃该存档后重新创建房间。");
                return;
            }
            run = save.SaveData;
        }
        if (overlay != null)
            overlay.Visible = true;
        try
        {
            var capacity = Math.Max(MaxPlayers, run?.Players.Count ?? 0);
#if STS2_TARGET_1071
            var netService = new NetHostGameService();
#else
            var netService = new NetHostGameService(PeerVersionInfo.LocalDefault());
#endif
            var error = netService.StartENetHost(GamePort, capacity);
            if (error.HasValue)
            {
                Log('E', $"StartENetHost(UDP {GamePort}, {capacity}) failed: {DescribeArg(error.Value)}");
                AddModal(NErrorPopup.Create(error.Value));
                return;
            }
            if (run == null)
            {
                var character = stack.GetSubmenuType<NCharacterSelectScreen>();
                character.InitializeMultiplayerAsHost(netService, capacity);
                stack.Push(character);
            }
            else
            {
                switch (run.GameMode)
                {
                    case GameMode.Daily:
                        var daily = stack.GetSubmenuType<NDailyRunLoadScreen>();
                        daily.InitializeAsHost(netService, run);
                        stack.Push(daily);
                        break;
                    case GameMode.Custom:
                        var custom = stack.GetSubmenuType<NCustomRunLoadScreen>();
                        custom.InitializeAsHost(netService, run);
                        stack.Push(custom);
                        break;
                    default:
                        var standard = stack.GetSubmenuType<NMultiplayerLoadGameScreen>();
                        standard.InitializeAsHost(netService, run);
                        stack.Push(standard);
                        break;
                }
            }
            Log('I', $"hosting on UDP {GamePort} (online={online}, continuing={run != null}, capacity={capacity}, game {BuiltForGameVersion})");
            ShowInfo(online ? "联机房间已开启" : "局域网房间已开启", online
                ? "朋友在启动器「联机小屋」的在线房间列表里就能看到并加入你的房间。玩的时候请保持启动器开着。"
                : $"朋友在启动器「联机小屋 → 局域网直连」填写你的局域网 IP 和端口 {GamePort} 即可加入（启动器里列出了本机 IP）。");
        }
        finally
        {
            if (overlay != null)
                overlay.Visible = false;
        }
    }

    private static Task Join(NMainMenu menu, JsonObject action)
    {
        var host = ReadString(action, "host")?.Trim();
        var port = ReadLong(action, "port");
        if (string.IsNullOrEmpty(host) || port is <= 0 or > 65535)
            throw new InvalidOperationException($"房间地址无效（{host}:{port}）。");
        if (!ulong.TryParse(ReadString(action, "playerId"), out var netId) || netId <= HostNetId)
            throw new InvalidOperationException("启动器没有提供有效的联机身份，请重新打开启动器后再试。");
        _localNetId = netId;
        Log('I', $"joining {host}:{port} as NetId {netId} (game {BuiltForGameVersion})");
        // NMainMenu.JoinGame 打开加入页并运行原版 JoinFlow，进入大厅后推入选角色（或续局）界面。
        return menu.JoinGame(new ENetClientConnectionInitializer(netId, host, (ushort)port));
    }

    private static HashSet<ulong> RawSavePlayerIds()
    {
        var ids = new HashSet<ulong>();
        try
        {
            var manager = AccessTools.Field(typeof(SaveManager), "_runSaveManager")?.GetValue(SaveManager.Instance);
            var result = manager?.GetType().GetMethod("LoadMultiplayerRunSave", BindingFlags.Public | BindingFlags.Instance, Type.EmptyTypes)?.Invoke(manager, null);
            var data = result?.GetType().GetProperty("SaveData")?.GetValue(result);
            if (data?.GetType().GetProperty("Players")?.GetValue(data) is IEnumerable players)
            {
                foreach (var player in players)
                {
                    if (player?.GetType().GetProperty("NetId")?.GetValue(player) is ulong id)
                        ids.Add(id);
                }
            }
        }
        catch (Exception e)
        {
            Log('W', $"could not read multiplayer save players: {e.Message}");
        }
        return ids;
    }

    private static void ShowInfo(string title, string body) =>
        AddModal(NErrorPopup.Create(title, body, showReportBugButton: false));

    private static void AddModal(Node popup)
    {
        if (popup != null)
            NModalContainer.Instance?.Add(popup);
    }
}
