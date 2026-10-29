using System.Runtime.CompilerServices;
using Godot;
using MegaCrit.Sts2.addons.mega_text;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Helpers;
using MegaCrit.Sts2.Core.Multiplayer;
using MegaCrit.Sts2.Core.Multiplayer.Connection;
using MegaCrit.Sts2.Core.Multiplayer.Game;
using MegaCrit.Sts2.Core.Nodes.CommonUi;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;
using MegaCrit.Sts2.Core.Platform;
using MegaCrit.Sts2.Core.Runs;
using MegaCrit.Sts2.Core.Saves;
using MegaCrit.Sts2.Core.Saves.Managers;

namespace STS2MobileIos.Patches;

/// <summary>Static NativeAOT hooks. Transport and handshake remain game owned.</summary>
public static class LanMultiplayerPatches
{
    private const int Capacity = 4;
    // These two field contracts are checked against the owned v0.111.0 DLL.
    // UnsafeAccessor generates direct access at compilation; no runtime reflection/JIT.
    [UnsafeAccessor(UnsafeAccessorKind.Field, Name = "_loadingOverlay")]
    private static extern ref Control LoadingOverlay(NMultiplayerSubmenu screen);
    [UnsafeAccessor(UnsafeAccessorKind.Field, Name = "_stack")]
    private static extern ref NSubmenuStack SubmenuStack(NSubmenu screen);

    public static bool LocalPlayerIdPrefix(ref ulong __result)
    {
        __result = LauncherConfigPatches.LocalPeerId;
        return false;
    }

    public static bool PlayerNamePrefix(ulong playerId, ref string __result)
    {
        if (playerId != LauncherConfigPatches.LocalPeerId) return true;
        __result = LauncherConfigPatches.Nickname;
        return false;
    }

    // Wire identity must never relocate an existing local account directory.
    // Preserve explicit paths for other platform accounts; default iOS stays default/1.
    public static void SaveAccountPrefix(ref ulong? userIdOverride, PlatformType? platformOverride)
    {
        if ((!platformOverride.HasValue || platformOverride.Value == PlatformType.None) &&
            (!userIdOverride.HasValue || userIdOverride.Value == LauncherConfigPatches.LocalPeerId))
            userIdOverride = 1UL;
    }

    // The original method renames an MP save as broken if canonicalization throws.
    // An identity mismatch is recoverable configuration, so reject before that path.
    public static bool CanonicalizePrefix(RunSaveManager __instance, ref ulong localPlayerId,
        ref ReadSaveResult<SerializableRun> __result)
    {
        var stableId = LauncherConfigPatches.LocalPeerId;
        localPlayerId = stableId;
        var raw = __instance.LoadMultiplayerRunSave();
        if (raw?.Success != true || raw.SaveData == null) return true;
        if (raw.SaveData.Players.Any(p => p.NetId == stableId)) return true;
        const string message = "LAN player ID does not match multiplayer save. Restore network.playerId from the original launcher config. The save has been preserved.";
        PatchHelper.Log(message);
        __result = new ReadSaveResult<SerializableRun>(ReadSaveStatus.ValidationFailed, message);
        return false;
    }

    public static bool HostPrefix(GameMode gameMode, Control loadingOverlay, NSubmenuStack stack, ref Task __result)
    {
        __result = Host(gameMode, loadingOverlay, stack, null);
        return false;
    }

    public static bool LoadedHostPrefix(NMultiplayerSubmenu __instance, SerializableRun run, ref Task __result)
    {
        if (!run.Players.Any(p => p.NetId == LauncherConfigPatches.LocalPeerId))
        {
            ShowInfo("无法继续多人存档", "当前玩家 ID 不在这个存档中。请恢复创建该存档时 Launcher/config.json 中的 network.playerId；不要删除原存档。");
            __result = Task.CompletedTask;
            return false;
        }
        __result = Host(run.GameMode, LoadingOverlay(__instance), SubmenuStack(__instance), run);
        return false;
    }

    private static Task Host(GameMode mode, Control overlay, NSubmenuStack stack, SerializableRun run)
    {
        overlay.Visible = true;
        NetHostGameService service = null;
        try
        {
            service = new NetHostGameService(PeerVersionInfo.LocalDefault());
            var error = service.StartENetHost((ushort)LauncherConfigPatches.Port, Capacity);
            if (error.HasValue)
            {
                NModalContainer.Instance.Add(NErrorPopup.Create(error.Value));
                return Task.CompletedTask;
            }
            if (run != null)
            {
                switch (mode)
                {
                    case GameMode.Daily:
                        var daily = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.DailyRun.NDailyRunLoadScreen>();
                        daily.InitializeAsHost(service, run); stack.Push(daily); break;
                    case GameMode.Custom:
                        var custom = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.CustomRun.NCustomRunLoadScreen>();
                        custom.InitializeAsHost(service, run); stack.Push(custom); break;
                    default:
                        var standard = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.CharacterSelect.NMultiplayerLoadGameScreen>();
                        standard.InitializeAsHost(service, run); stack.Push(standard); break;
                }
            }
            else
            {
                switch (mode)
                {
                    case GameMode.Standard:
                        var standard = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.CharacterSelect.NCharacterSelectScreen>();
                        standard.InitializeMultiplayerAsHost(service, Capacity); stack.Push(standard); break;
                    case GameMode.Daily:
                        var daily = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.DailyRun.NDailyRunScreen>();
                        daily.InitializeMultiplayerAsHost(service); stack.Push(daily); break;
                    default:
                        var custom = stack.GetSubmenuType<MegaCrit.Sts2.Core.Nodes.Screens.CustomRun.NCustomRunScreen>();
                        custom.InitializeMultiplayerAsHost(service, Capacity); stack.Push(custom); break;
                }
            }
            // Online rooms are announced through the launcher's room list; no popup over the lobby.
            if (!RemoteRoomPatches.HostingOnlineRoom)
                ShowInfo("ENet 房间已开启", $"UDP 端口：{LauncherConfigPatches.Port}。其他玩家输入本机 Wi-Fi IP 加入。公网连接需要可达的 UDP 端口转发或 VPN。游戏仍会检查版本与 MOD。");
        }
        catch (Exception e)
        {
            service?.Disconnect(NetError.InternalError);
            PatchHelper.Log($"LAN host failed: {e}");
            ShowInfo("开房失败", e.Message);
        }
        finally { overlay.Visible = false; }
        return Task.CompletedTask;
    }

    public static bool JoinOpenedPrefix(NJoinFriendScreen __instance)
    {
        ConfigureJoin(__instance);
        return false;
    }

    public static bool JoinRefreshPrefix(NJoinFriendScreen __instance)
    {
        TaskHelper.RunSafely(Join(__instance));
        return false;
    }

    // The original OnSubmenuClosed cancels the same _currentJoinFlow we assign.
    private static async Task Join(NJoinFriendScreen screen)
    {
        if (screen.HasMeta("ios_lan_joining") && screen.GetMeta("ios_lan_joining").AsBool()) return;
        var panel = screen.GetNode<VBoxContainer>("Panel/IosLanJoin");
        var host = panel.GetNode<LineEdit>("Host").Text.Trim();
        if (string.IsNullOrWhiteSpace(host) || host.Any(char.IsWhiteSpace) ||
            !ushort.TryParse(panel.GetNode<LineEdit>("Port").Text, out var port) || port == 0)
        { ShowInfo("无法加入", "请输入房主 IP 或主机名，以及 1–65535 的端口。"); return; }
        LauncherConfigPatches.Host = host;
        LauncherConfigPatches.Port = port;
        LauncherConfigPatches.Nickname = panel.GetNode<LineEdit>("Nickname").Text;
        screen.SetMeta("ios_lan_joining", true);
        try
        {
            // v0.111.0 JoinGameAsync itself constructs the versioned NetClientGameService
            // and JoinFlow, stores _currentJoinFlow, and keeps cancellation/error UI.
            await screen.JoinGameAsync(new ENetClientConnectionInitializer(LauncherConfigPatches.LocalPeerId, host, port));
        }
        catch (Exception e) { PatchHelper.Log($"LAN join failed: {e}"); if (GodotObject.IsInstanceValid(screen)) ShowInfo("加入失败", e.Message); }
        finally { if (GodotObject.IsInstanceValid(screen)) screen.SetMeta("ios_lan_joining", false); }
    }

    private static void ConfigureJoin(NJoinFriendScreen screen)
    {
        foreach (var path in new[] { "%LoadingOverlay", "%ButtonContainer", "%LoadingIndicator", "%NoFriendsText" })
        { var node = screen.GetNodeOrNull<Control>(path); if (node != null) node.Visible = false; }
        screen.GetNodeOrNull<MegaLabel>("TitleLabel")?.SetTextAutoSize("加入 IP 房间");
        var panel = screen.GetNode<Control>("Panel");
        var form = panel.GetNodeOrNull<VBoxContainer>("IosLanJoin");
        if (form == null)
        {
            form = new VBoxContainer { Name = "IosLanJoin", AnchorLeft = .5f, AnchorRight = .5f, AnchorTop = .5f, AnchorBottom = .5f,
                OffsetLeft = -330, OffsetRight = 330, OffsetTop = -90, OffsetBottom = 240 };
            form.AddThemeConstantOverride("separation", 14);
            form.AddChild(new Label { Text = "同一局域网输入房主 IP；公网需 UDP 转发或 VPN。", AutowrapMode = TextServer.AutowrapMode.WordSmart });
            AddInput(form, "Nickname", "玩家昵称", 32);
            AddInput(form, "Host", "房主 IP / 主机名", 253);
            AddInput(form, "Port", "UDP 端口", 5);
            panel.AddChild(form);
        }
        form.GetNode<LineEdit>("Nickname").Text = LauncherConfigPatches.Nickname;
        form.GetNode<LineEdit>("Host").Text = LauncherConfigPatches.Host;
        form.GetNode<LineEdit>("Port").Text = LauncherConfigPatches.Port.ToString();
        var button = screen.GetNodeOrNull<Control>("RefreshButton");
        button?.GetNodeOrNull<MegaLabel>("Label")?.SetTextAutoSize("加入");
    }

    private static void AddInput(VBoxContainer form, string name, string placeholder, int max)
    {
        var input = new LineEdit { Name = name, PlaceholderText = placeholder, MaxLength = max, CustomMinimumSize = new Vector2(0, 52) };
        input.AddThemeFontSizeOverride("font_size", 26);
        form.AddChild(input);
        input.TextSubmitted += _ => { var screen = form.GetParent().GetParent() as NJoinFriendScreen; if (screen != null) TaskHelper.RunSafely(Join(screen)); };
    }
    private static void ShowInfo(string title, string body) => NModalContainer.Instance.Add(NErrorPopup.Create(title, body, showReportBugButton: false));
}
