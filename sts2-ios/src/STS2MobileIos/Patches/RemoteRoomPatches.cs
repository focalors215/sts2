using Godot;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Helpers;
using MegaCrit.Sts2.Core.Multiplayer.Connection;
using MegaCrit.Sts2.Core.Nodes.CommonUi;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;
using MegaCrit.Sts2.Core.Runs;
using MegaCrit.Sts2.Core.Saves;

namespace STS2MobileIos.Patches;

/// <summary>
/// One-shot action handed over by the native launcher (Documents/Launcher/pending-action.json,
/// 三端规范 §3.3): "host" opens the multiplayer lobby as host, "join" connects to a room.
/// Both end in the game's own lobby screens. Every decision is written to online-game.log.
/// </summary>
public static class RemoteRoomPatches
{
    private static bool _consumed;

    /// <summary>True when the current ENet host was created for an online (frp) room.</summary>
    public static bool HostingOnlineRoom { get; private set; }

    private static string ActionPath => Path.Combine(OS.GetUserDataDir(), "Launcher", "pending-action.json");

    // Called from MobileLayoutPatches.MainMenuReadyPostfix (NMainMenu._Ready).
    public static void OnMainMenuReady(Node menuNode)
    {
        ClearLaunchMarker();
        if (_consumed || menuNode is not NMainMenu menu) return;
        _consumed = true;
        var action = TakeAction();
        if (action != null) TaskHelper.RunSafely(Run(menu, action));
    }

    private static bool _markerCleared;

    // 规范 §5.4：游戏进入主菜单 = 启动成功，删除启动器写的 launch-marker.json；
    // 残留标记会让启动器下次打开时提示「上次游戏异常退出」。
    private static void ClearLaunchMarker()
    {
        if (_markerCleared) return;
        _markerCleared = true;
        var path = Path.Combine(OS.GetUserDataDir(), "Launcher", "launch-marker.json");
        try
        {
            if (!File.Exists(path)) return;
            File.Delete(path);
            PatchHelper.Log("[Launcher] Main menu reached; launch marker cleared.");
        }
        catch (Exception e) { PatchHelper.Log($"[Launcher] Could not clear launch marker: {e.Message}"); }
    }

    // Read once and delete, so returning to the main menu never repeats the action.
    private static PendingAction TakeAction()
    {
        string json;
        try
        {
            if (!File.Exists(ActionPath)) return null;
            json = File.ReadAllText(ActionPath);
        }
        catch (Exception e)
        {
            OnlineRoomLog.Error("读取联机指令失败，已丢弃", e);
            Delete();
            return PendingAction.Failure("无法读取启动器的联机指令，请回到启动器重试。");
        }
        Delete();
        var action = PendingAction.Parse(json, DateTimeOffset.UtcNow);
        if (action.Expired)
        {
            OnlineRoomLog.Warn($"丢弃联机指令: {action.Error}");
            return null;
        }
        if (action.Error != null)
        {
            OnlineRoomLog.Error($"联机指令无效: {action.Error}");
            return action;
        }
        OnlineRoomLog.Info($"读取联机指令: type={action.Type} online={action.Online} host={action.Host} port={action.Port} created={action.Created}");
        if (!string.IsNullOrEmpty(action.PlayerId) &&
            action.PlayerId != LauncherConfigPatches.LocalPeerId.ToString(System.Globalization.CultureInfo.InvariantCulture))
            OnlineRoomLog.Warn($"指令中的 playerId 与 config.json 不一致，以 config.json 为准（指令 {action.PlayerId}）。");
        return action;
    }

    private static void Delete()
    {
        try { File.Delete(ActionPath); }
        catch (Exception e) { OnlineRoomLog.Warn("删除联机指令文件失败", e); }
    }

    private static async Task Run(NMainMenu menu, PendingAction action)
    {
        // Let the menu finish its first layout and patch-notes setup.
        var tree = menu.GetTree();
        await menu.ToSignal(tree.CreateTimer(0.6), Godot.Timer.SignalName.Timeout);
        if (!GodotObject.IsInstanceValid(menu) || !menu.IsInsideTree())
        {
            OnlineRoomLog.Warn("主菜单在执行联机指令前已关闭，指令未执行。");
            return;
        }
        if (action.Error != null)
        {
            ShowInfo("联机指令无效", action.Error);
            return;
        }
        try
        {
            if (action.Type == "host") Host(menu, action);
            else await Join(menu, action);
        }
        catch (Exception e)
        {
            OnlineRoomLog.Error(action.Type == "host" ? "开房失败" : "加入失败", e);
            ShowInfo(action.Type == "host" ? "开房失败" : "加入失败", e.Message);
        }
    }

    private static void Host(NMainMenu menu, PendingAction action)
    {
        HostingOnlineRoom = action.Online;
        var submenu = menu.OpenMultiplayerSubmenu();
        if (!SaveManager.Instance.HasMultiplayerRunSave)
        {
            OnlineRoomLog.Info($"开房（新局）: UDP {LauncherConfigPatches.Port}，{(action.Online ? "在线房间" : "局域网")}");
            // Goes through NMultiplayerHostSubmenu.StartHostAsync → LanMultiplayerPatches.HostPrefix.
            submenu.FastHost(GameMode.Standard);
            return;
        }
        // Same as the original "continue" button: the room resumes the saved run.
        OnlineRoomLog.Info($"开房（续局）: UDP {LauncherConfigPatches.Port}，playerId={LauncherConfigPatches.LocalPeerId}");
        var save = SaveManager.Instance.LoadAndCanonicalizeMultiplayerRunSave(LauncherConfigPatches.LocalPeerId);
        if (save.Success && save.SaveData != null) submenu.StartHost(save.SaveData);
        else
        {
            OnlineRoomLog.Error($"续局失败: 多人存档读取失败 status={save.Status} {save.ErrorMessage}");
            ShowInfo("无法继续多人存档", save.Status == ReadSaveStatus.ValidationFailed && !string.IsNullOrEmpty(save.ErrorMessage)
                ? save.ErrorMessage
                : "多人存档读取失败。可在游戏多人菜单中放弃该存档后重新创建房间。");
        }
    }

    private static Task Join(NMainMenu menu, PendingAction action)
    {
        OnlineRoomLog.Info($"加入 {action.Host}:{action.Port}（{(action.Online ? "在线房间" : "局域网直连")}），playerId={LauncherConfigPatches.LocalPeerId}");
        // NMainMenu.JoinGame opens the join screen and runs the original JoinFlow,
        // which pushes the character select (or load) screen once in the lobby.
        return menu.JoinGame(new ENetClientConnectionInitializer(LauncherConfigPatches.LocalPeerId, action.Host, (ushort)action.Port));
    }

    private static void ShowInfo(string title, string body) =>
        NModalContainer.Instance?.Add(NErrorPopup.Create(title, body, showReportBugButton: false));
}
