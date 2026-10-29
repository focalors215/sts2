using System.Text.Json.Nodes;
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
/// One-shot action handed over by the native launcher's online room list
/// (Documents/Launcher/pending-action.json): "host" opens the multiplayer lobby as
/// host, "join" connects to a room. Both end in the game's own lobby screens.
/// </summary>
public static class RemoteRoomPatches
{
    private static bool _consumed;

    /// <summary>True when the current ENet host was created for an online room.</summary>
    public static bool HostingOnlineRoom { get; private set; }

    private static string ActionPath => Path.Combine(OS.GetUserDataDir(), "Launcher", "pending-action.json");

    // Called from MobileLayoutPatches.MainMenuReadyPostfix (NMainMenu._Ready).
    public static void OnMainMenuReady(Node menuNode)
    {
        if (_consumed || menuNode is not NMainMenu menu) return;
        _consumed = true;
        var action = TakeAction();
        if (action != null) TaskHelper.RunSafely(Run(menu, action));
    }

    // Read once and delete, so returning to the main menu never repeats the action.
    private static JsonObject TakeAction()
    {
        try
        {
            if (!File.Exists(ActionPath)) return null;
            var action = JsonNode.Parse(File.ReadAllText(ActionPath)) as JsonObject;
            File.Delete(ActionPath);
            return action;
        }
        catch (Exception e)
        {
            PatchHelper.Log($"[OnlineRoom] Could not read pending action: {e.Message}");
            try { File.Delete(ActionPath); } catch { }
            return null;
        }
    }

    private static async Task Run(NMainMenu menu, JsonObject action)
    {
        // Let the menu finish its first layout and patch-notes setup.
        var tree = menu.GetTree();
        await menu.ToSignal(tree.CreateTimer(0.6), Godot.Timer.SignalName.Timeout);
        if (!GodotObject.IsInstanceValid(menu) || !menu.IsInsideTree()) return;
        var type = action["type"]?.GetValue<string>();
        try
        {
            if (type == "host") Host(menu);
            else if (type == "join") await Join(menu, action);
            else PatchHelper.Log($"[OnlineRoom] Unknown action {type}");
        }
        catch (Exception e)
        {
            PatchHelper.Log($"[OnlineRoom] {type} failed: {e}");
            ShowInfo(type == "host" ? "开房失败" : "加入失败", e.Message);
        }
    }

    private static void Host(NMainMenu menu)
    {
        HostingOnlineRoom = true;
        var submenu = menu.OpenMultiplayerSubmenu();
        if (!SaveManager.Instance.HasMultiplayerRunSave)
        {
            // Goes through NMultiplayerHostSubmenu.StartHostAsync → LanMultiplayerPatches.HostPrefix.
            submenu.FastHost(GameMode.Standard);
            return;
        }
        // Same as the original "continue" button: the room resumes the saved run.
        var save = SaveManager.Instance.LoadAndCanonicalizeMultiplayerRunSave(LauncherConfigPatches.LocalPeerId);
        if (save.Success && save.SaveData != null) submenu.StartHost(save.SaveData);
        else ShowInfo("无法继续多人存档", "多人存档读取失败。可在游戏多人菜单中放弃该存档后重新创建房间。");
    }

    private static Task Join(NMainMenu menu, JsonObject action)
    {
        var host = action["host"]?.GetValue<string>();
        var port = action["port"]?.GetValue<int>() ?? 0;
        if (string.IsNullOrWhiteSpace(host) || port is <= 0 or > 65535)
            throw new InvalidOperationException("房间地址无效。");
        PatchHelper.Log($"[OnlineRoom] Joining {host}:{port}");
        // NMainMenu.JoinGame opens the join screen and runs the original JoinFlow,
        // which pushes the character select (or load) screen once in the lobby.
        return menu.JoinGame(new ENetClientConnectionInitializer(LauncherConfigPatches.LocalPeerId, host, (ushort)port));
    }

    private static void ShowInfo(string title, string body) =>
        NModalContainer.Instance.Add(NErrorPopup.Create(title, body, showReportBugButton: false));
}
