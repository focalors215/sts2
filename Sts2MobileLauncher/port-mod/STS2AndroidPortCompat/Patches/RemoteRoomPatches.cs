using System;
using System.IO;
using System.Threading.Tasks;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Helpers;
using MegaCrit.Sts2.Core.Nodes.CommonUi;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;
using STS2Mobile.Android;
#if STS2_TARGET_1071 || STS2_TARGET_1110
using MegaCrit.Sts2.Core.Multiplayer.Connection;
using MegaCrit.Sts2.Core.Platform;
using MegaCrit.Sts2.Core.Runs;
using MegaCrit.Sts2.Core.Saves;
#endif

namespace STS2Mobile.Patches;

/// <summary>
/// One-shot action handed over by the launcher's online room list (联机小屋,
/// DataDir/launcher/pending-action.json): "host" opens the multiplayer lobby as
/// host behind the launcher's frp tunnel, "join" connects to a room on the frp
/// server. Contract: doc/architecture/cross-platform-parity.md §3.3/§3.4; the
/// Windows (STS2CottageOnline) and iPad launchers implement the same file.
/// Supported on the v0.107.1 and v0.111.0 targets (identical host/join APIs apart
/// from the NetHostGameService constructor, which LanMultiplayerPatches handles).
/// </summary>
public static class RemoteRoomPatches
{
#if STS2_TARGET_1071 || STS2_TARGET_1110
    public const bool Supported = true;
#else
    public const bool Supported = false;
#endif

    private static bool _consumed;

    /// <summary>True when the current ENet host was created for an online room.</summary>
    public static bool HostingOnlineRoom { get; private set; }

    /// <summary>True once a launcher host/join action ran in this process; network errors are then logged as [OnlineRoom].</summary>
    public static bool OnlineSessionStarted { get; private set; }

    private static string ActionPath => Path.Combine(AppPaths.DataDir, "launcher", "pending-action.json");

    // Called from LanMultiplayerPatches.Apply once the LAN patches are active.
    public static void Apply(Harmony harmony)
    {
        try
        {
            var create = AccessTools.Method(typeof(NErrorPopup), "Create", new[] { typeof(NetErrorInfo) });
            if (create == null)
            {
                PatchHelper.Log("SKIPPED NErrorPopup.Create(NetErrorInfo): method not found");
                return;
            }
            harmony.Patch(create, prefix: new HarmonyMethod(PatchHelper.Method(typeof(RemoteRoomPatches), nameof(NetErrorPopupPrefix))));
            PatchHelper.Log("Patched NErrorPopup.Create(NetErrorInfo) for [OnlineRoom] error logging");
        }
        catch (Exception exception)
        {
            PatchHelper.Log($"FAILED NErrorPopup.Create(NetErrorInfo) logging patch: {exception}");
        }
    }

    // Records handshake/disconnect failures (original error text) while an online room session is active.
    public static void NetErrorPopupPrefix(NetErrorInfo info)
    {
        if (!OnlineSessionStarted)
            return;
        try
        {
            OnlineRoomLog.Error($"联机网络错误: reason={info.GetReason()} selfInitiated={info.SelfInitiated} detail={info}");
        }
        catch (Exception exception)
        {
            PatchHelper.Log($"[OnlineRoom] Could not describe network error: {exception.Message}");
        }
    }

    // Called from LanMultiplayerBootstrapPatches.MainMenuReadyPostfix (NMainMenu._Ready).
    public static void OnMainMenuReady(NMainMenu menu)
    {
        if (_consumed || menu == null)
            return;
        _consumed = true;
        var action = TakeAction();
        if (action != null)
            TaskHelper.RunSafely(Run(menu, action));
    }

    // Read once and delete, so returning to the main menu never repeats the action.
    private static OnlineRoomProtocol.PendingAction TakeAction()
    {
        string json;
        try
        {
            if (!File.Exists(ActionPath))
                return null;
            json = File.ReadAllText(ActionPath);
        }
        catch (Exception exception)
        {
            OnlineRoomLog.Error("读取联机指令失败", exception);
            DeleteAction();
            ShowInfo("联机指令无效", "读取启动器联机指令失败，请回到启动器重试。详见联机日志。");
            return null;
        }
        DeleteAction();

        var action = OnlineRoomProtocol.ParsePendingAction(json, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), out var error, out var warning);
        if (action == null)
        {
            OnlineRoomLog.Error($"丢弃联机指令: {error}");
            ShowInfo("联机指令无效", error);
            return null;
        }
        if (warning != null)
            OnlineRoomLog.Warn(warning);
        OnlineRoomLog.Info($"读取联机指令 type={action.Type} online={action.Online} created={action.Created}" + (action.Type == "join" ? $" target={action.Host}:{action.Port}" : string.Empty));
        return action;
    }

    private static void DeleteAction()
    {
        try
        {
            File.Delete(ActionPath);
        }
        catch (Exception exception)
        {
            OnlineRoomLog.Warn("删除联机指令文件失败", exception);
        }
    }

    private static async Task Run(NMainMenu menu, OnlineRoomProtocol.PendingAction action)
    {
        // Let the menu finish its first layout and patch-notes setup.
        var tree = menu.GetTree();
        await menu.ToSignal(tree.CreateTimer(0.6), Godot.Timer.SignalName.Timeout);
        if (!GodotObject.IsInstanceValid(menu) || !menu.IsInsideTree())
        {
            OnlineRoomLog.Warn($"主菜单已离开场景树，放弃联机指令 {action.Type}");
            return;
        }
        try
        {
            if (!LanMultiplayerPatches.Applied)
                throw new InvalidOperationException("局域网联机已在启动器设置中关闭（或检测到大厅类 MOD），无法使用联机小屋。");
            if (!Supported)
                throw new NotSupportedException("当前兼容包的这个游戏版本不支持联机小屋，请使用 v0.107.1 或 v0.111.0，并在启动器「版本 → 兼容包」更新兼容包。");
            OnlineSessionStarted = true;
            var localPeerId = LanMultiplayerPatches.GetOrCreateLocalPeerId();
            if (action.PlayerId != 0 && action.PlayerId != localPeerId)
                OnlineRoomLog.Warn($"启动器传入的 playerId={action.PlayerId} 与游戏设置中的玩家 ID={localPeerId} 不一致，以游戏设置为准");
#if STS2_TARGET_1071 || STS2_TARGET_1110
            if (action.Type == "host")
            {
                LanMultiplayerPatches.SetOnlineNickname(action.Nickname, OnlineRoomProtocol.HostNetId);
                Host(menu);
            }
            else
            {
                LanMultiplayerPatches.SetOnlineNickname(action.Nickname, localPeerId);
                await Join(menu, action, localPeerId);
            }
#endif
        }
        catch (Exception e)
        {
            OnlineRoomLog.Error($"{action.Type} 失败", e);
            ShowInfo(action.Type == "host" ? "开房失败" : "加入失败", e.Message);
        }
    }

#if STS2_TARGET_1071 || STS2_TARGET_1110
    private static void Host(NMainMenu menu)
    {
        HostingOnlineRoom = true;
        var submenu = menu.OpenMultiplayerSubmenu();
        if (!SaveManager.Instance.HasMultiplayerRunSave)
        {
            OnlineRoomLog.Info($"开房（新局），本机 UDP {LanMultiplayerPatches.DefaultPort}");
            // Goes through NMultiplayerHostSubmenu.StartHostAsync → LanMultiplayerPatches.HostSubmenuStartHostAsyncPrefix.
            submenu.FastHost(GameMode.Standard);
            return;
        }
        // Same as the original "continue" button: the room resumes the saved run.
        // LanMultiplayerPatches resolves the save identity (§3.4) inside this call.
        var save = SaveManager.Instance.LoadAndCanonicalizeMultiplayerRunSave(PlatformUtil.GetLocalPlayerId(PlatformType.None));
        if (save.Success && save.SaveData != null)
        {
            OnlineRoomLog.Info($"开房（续局），本机 UDP {LanMultiplayerPatches.DefaultPort}，存档玩家数 {save.SaveData.Players.Count}");
            // Goes through NMultiplayerSubmenu.StartHostAsync → LanMultiplayerPatches.MultiplayerSubmenuStartHostAsyncPrefix (role check).
            submenu.StartHost(save.SaveData);
            return;
        }
        var reason = LanMultiplayerPatches.LastSaveIdentityError ?? $"多人存档读取失败（{save.Status}）。可在游戏多人菜单中放弃该存档后重新创建房间。";
        OnlineRoomLog.Error($"无法续局: status={save.Status} {save.ErrorMessage}");
        ShowInfo("无法继续多人存档", reason);
    }

    private static Task Join(NMainMenu menu, OnlineRoomProtocol.PendingAction action, ulong localPeerId)
    {
        OnlineRoomLog.Info($"加入房间 {action.Host}:{action.Port}，本机 NetId={localPeerId}");
        // NMainMenu.JoinGame opens the join screen and runs the original JoinFlow,
        // which pushes the character select (or load) screen once in the lobby.
        return menu.JoinGame(new ENetClientConnectionInitializer(localPeerId, action.Host, (ushort)action.Port));
    }
#endif

    private static void ShowInfo(string title, string body) =>
        NModalContainer.Instance?.Add(NErrorPopup.Create(title, body, showReportBugButton: false));
}
