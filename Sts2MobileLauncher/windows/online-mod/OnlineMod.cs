using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
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
/// （与 Android / iPad 的 RemoteRoomPatches 同一协议）："host" 在本机 UDP 33771 用游戏自带的
/// ENet 开房（在线房间由启动器的 frp 映射到服务器），"join" 用原版 JoinFlow 连到房间地址。
/// 不改消息、序列化、版本或 ModelDb 校验；Steam 好友联机照常可用。
/// </summary>
[ModInitializer(nameof(Initialize))]
public static class OnlineMod
{
    public const string ModId = "STS2CottageOnline";
    private const ushort GamePort = 33771; // NMultiplayerHostSubmenu 原版 ENet 端口，联机小屋各端相同
    private const int MaxPlayers = 4;
    private const ulong HostNetId = 1; // NullPlatformUtilStrategy.LocalPlayerId，ENet 房主身份
    private const long MaxActionAgeSeconds = 600;

    private static bool _consumed;
    private static ulong _localNetId;
    private static string _nickname;

    private static string ActionPath => ProjectSettings.GlobalizePath("user://launcher/pending-action.json");

    public static void Initialize()
    {
        var harmony = new Harmony("sts2.cottage.online");
        Patch(harmony, typeof(NMainMenu), "_Ready", postfix: nameof(MainMenuReadyPostfix));
        Patch(harmony, typeof(NullPlatformUtilStrategy), "GetPlayerName", prefix: nameof(NullGetPlayerNamePrefix));
        Patch(harmony, typeof(UserDataPathProvider), "set_IsRunningModded", prefix: nameof(SetIsRunningModdedPrefix));
        Log("loaded");
    }

    private static void Patch(Harmony harmony, Type type, string method, string prefix = null, string postfix = null)
    {
        try
        {
            var target = AccessTools.Method(type, method);
            if (target == null)
            {
                Log($"skip {type.Name}.{method}: not found");
                return;
            }
            harmony.Patch(target,
                prefix: prefix == null ? null : new HarmonyMethod(typeof(OnlineMod), prefix),
                postfix: postfix == null ? null : new HarmonyMethod(typeof(OnlineMod), postfix));
        }
        catch (Exception e)
        {
            Log($"patch {type.Name}.{method} failed: {e.Message}");
        }
    }

    private static void Log(string message) => GD.Print($"[CottageOnline] {message}");

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
            Log($"modded save dir check failed: {e.Message}");
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
        var action = TakeAction();
        if (action != null)
            TaskHelper.RunSafely(Run(__instance, action));
    }

    // 读一次就删，回到主菜单不会重复执行；过期指令（启动器异常退出留下的）直接丢弃。
    private static JsonObject TakeAction()
    {
        try
        {
            if (!File.Exists(ActionPath))
                return null;
            var action = JsonNode.Parse(File.ReadAllText(ActionPath)) as JsonObject;
            File.Delete(ActionPath);
            var created = action?["created"]?.GetValue<long>() ?? 0;
            if (Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - created) > MaxActionAgeSeconds)
            {
                Log("ignored stale pending action");
                return null;
            }
            return action;
        }
        catch (Exception e)
        {
            Log($"could not read pending action: {e.Message}");
            try { File.Delete(ActionPath); } catch { }
            return null;
        }
    }

    private static async Task Run(NMainMenu menu, JsonObject action)
    {
        // 等主菜单完成第一次布局与更新说明。
        await menu.ToSignal(menu.GetTree().CreateTimer(0.6), Godot.Timer.SignalName.Timeout);
        if (!GodotObject.IsInstanceValid(menu) || !menu.IsInsideTree())
            return;
        var type = action["type"]?.GetValue<string>();
        _nickname = action["nickname"]?.GetValue<string>();
        var online = action["online"]?.GetValue<bool>() ?? false;
        try
        {
            if (type == "host")
                Host(menu, online);
            else if (type == "join")
                await Join(menu, action);
            else
                Log($"unknown action {type}");
        }
        catch (Exception e)
        {
            Log($"{type} failed: {e}");
            ShowInfo(type == "host" ? "开房失败" : "加入失败", e.Message);
        }
    }

    private static void Host(NMainMenu menu, bool online)
    {
        _localNetId = HostNetId;
        var submenu = menu.OpenMultiplayerSubmenu();
        var stack = (NSubmenuStack)AccessTools.Field(typeof(NSubmenu), "_stack").GetValue(submenu);
        var overlay = AccessTools.Field(typeof(NMultiplayerSubmenu), "_loadingOverlay")?.GetValue(submenu) as Control;
        SerializableRun run = null;
        if (SaveManager.Instance.HasMultiplayerRunSave)
        {
            // 与原版“继续”相同：房间续上这一局。先确认存档里有 ENet 房主身份，避免
            // 原版 canonicalization 因身份不符把存档当成损坏文件改名。
            var ids = RawSavePlayerIds();
            if (!ids.Contains(HostNetId))
            {
                ShowInfo("无法用这份多人存档开房", "这份多人存档不是在联机小屋里由你当房主创建的（可能来自 Steam 好友联机或你加入的别人的房间）。"
                    + "请在游戏多人菜单里继续或放弃它后再创建房间。");
                return;
            }
            var save = SaveManager.Instance.LoadAndCanonicalizeMultiplayerRunSave(HostNetId);
            if (!save.Success || save.SaveData == null)
            {
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
            Log($"hosting on UDP {GamePort} (online={online}, continuing={run != null})");
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
        var host = action["host"]?.GetValue<string>()?.Trim();
        var port = action["port"]?.GetValue<int>() ?? 0;
        if (string.IsNullOrEmpty(host) || port is <= 0 or > 65535)
            throw new InvalidOperationException("房间地址无效。");
        if (!ulong.TryParse(action["playerId"]?.GetValue<string>(), out var netId) || netId <= HostNetId)
            throw new InvalidOperationException("启动器没有提供有效的联机身份，请重新打开启动器后再试。");
        _localNetId = netId;
        Log($"joining {host}:{port}");
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
            Log($"could not read multiplayer save players: {e.Message}");
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
