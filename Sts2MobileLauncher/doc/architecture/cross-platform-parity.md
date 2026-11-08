# 三端统一规范：联机、联机 MOD、日志、功能对齐

适用于 Android（`android/` + `port-mod/`）、Windows（`windows/`）、iPad（独立仓库 `sts2-ios/`）三个启动器。
**Android 是功能基准**：其他两端的行为、文案、数据格式以 Android 为准；Android 自身缺的跨端能力（日志规范、v0.107.1 联机等）也按本文补齐。
本文是三端并行开发的约定，任何一端要改协议或格式，先改本文。

## 1. 目标

1. 三端可以通过同一台 frp 服务器互相看到房间并加入（远程联机），同网段也能局域网直连。
2. 启动器自动安装/启用联机组件，玩家不用在游戏里手动操作：启动器点「创建房间 / 加入」后，游戏到主菜单自动开房或加入。
3. 所有报错（启动器、游戏内联机组件、frp、MOD、存档、云同步、下载）都有可导出的日志。
4. 三端启动器功能一致（平台本身不存在的功能除外，见 §6）。

## 2. 游戏版本矩阵

联机握手要求双方游戏版本、ModelDb hash、游戏相关 MOD 列表完全一致，跨版本永远不能联机。

| 游戏版本 | Windows（PC 原版） | Android | iPad | 说明 |
| --- | --- | --- | --- | --- |
| v0.107.1 | 必须支持（Steam 当前公开版） | 兼容包已支持（2026-11-09，编译通过，**未真机验证**） | 暂不支持（需另做一套 iOS AOT 构建，单独评估） | |
| v0.111.0 | 必须支持（Steam beta 分支） | 必须支持（已验证） | 已支持（已验证与 Android 同 Wi-Fi 互联） | 三端互通的版本 |

房间卡里的 `version` 与本机版本不同时，加入按钮禁用并显示「版本不同」。

## 3. 联机协议（三端已一致，不要改）

### 3.1 游戏内传输

- 只使用游戏自带的 ENet 传输与原版 `JoinFlow` 握手，**不新增网络消息、不改序列化、不放宽版本/ModelDb 校验**。
- 本机 ENet 端口固定 UDP `33771`，最多 4 人。
- Windows 侧由启动器内置的「小屋联机组件」MOD `STS2CottageOnline`（`windows/online-mod/`）实现，`affects_gameplay: false`，不进入游戏相关 MOD 列表；Android 由兼容包内的 `LanMultiplayerPatches` + `RemoteRoomPatches` 实现；iPad 由静态织入的同名补丁实现。
- 第三方「LAN Multiplayer: Reforged」不能跨端（需要手动点、依赖 Harmony/BaseLib，iPad 无法加载），**不再打包**。启动器安装小屋联机组件时，如发现 Reforged、旧 `SlayTheSpire2.LAN.Multiplayer` 已启用，自动在 `settings.save` 中禁用它们并写日志（不删除文件）。

### 3.2 在线房间（frp）

- 服务器 20 个槽位：槽位 `i` 把房主本机 UDP 33771 映射到服务器 UDP `33771+i`（代理名 `sts2-room-<i>-game`），房间卡 JSON 发布在服务器 TCP `34771+i`（代理名 `sts2-room-<i>-card`）。
- 列表：并发探测 20 个 TCP 端口，每个读到对端关闭（最多 8 KiB、超时 2.5 s），能解析成 JSON 对象就是一个房间。可加入的端口由槽位推出，不信任卡片里的 `port`。
- 开房：先扫描，按顺序尝试空槽位（最多 3 个），遇到「已占用」换下一个；frp 确认两个代理都在运行后才算成功（超时 20 s）。
- 房间卡 v1：

```json
{ "v": 1, "name": "昵称的房间", "host": "昵称", "version": "v0.111.0", "continuing": false,
  "created": 1762650000, "slot": 3, "port": 33774, "platform": "android|windows|ios" }
```

  `platform` 三端都要写（Android 已于 2026-11-09 补上并在房间列表显示平台；iPad 待补）；读取方忽略未知字段，旧卡片没有 `platform` 时不显示平台。
- frp：官方 frp v0.71.1，TLS，`token` 认证。公开安装包只内嵌服务器地址和端口，**不内嵌令牌**；加入不需要令牌，开房时向用户索要令牌，只保存在本机（Windows 只在进程内；移动端在本机配置，不进备份/日志/导出）。

### 3.3 启动器 → 游戏的一次性指令 `pending-action.json`

位置：游戏 `user://` 下 —— Android `DataDir/launcher/pending-action.json`，Windows `%APPDATA%/SlayTheSpire2/launcher/pending-action.json`，iPad `Documents/Launcher/pending-action.json`。

```json
{ "v": 1, "type": "host|join", "created": 1762650000, "online": true,
  "host": "server.example.com", "port": 33774, "nickname": "喵喵零", "playerId": "1234567890123" }
```

- `type=host`：主菜单就绪约 0.6 s 后打开多人菜单开房；有多人存档时按原版「继续」续局。`host/port` 忽略。
- `type=join`：用 `ENetClientConnectionInitializer(<本机稳定 playerId>, host, port)` 走原版 `NMainMenu.JoinGame`。
- 读一次即删除；`created` 距今超过 600 s 视为过期，丢弃并写日志（三端都要做）。
- 解析失败、未知 `type`、地址非法、版本不支持：游戏内弹出中文错误框 **并且** 写日志。

### 3.4 身份与续局（2026-11-09 定稿，三端照此实现）

**事实（v0.107.1 与 v0.111.0 原版代码相同）**：

- `ENetHost.NetId` 固定返回 `1`，`ENetClient.HostNetId` 也固定为 `1`；客户端的 NetId 就是 `ENetClientConnectionInitializer` 构造时传入的 `netId`。这是传输层写死的，任何一端都**不能**改房主 NetId（改了客户端会找不到房主）。
- 开局大厅 `StartRunLobby` / 续局大厅 `LoadRunLobby` 用 `NetService.NetId` 作为本机玩家 ID，所以多人存档 `current_run_mp.save` 的 `Players[].NetId` 里：**房主那一位永远是 `1`，加入方是各自的 `playerId`**。每个参与者本地都会存一份同样内容的存档。
- 续局时房主调用 `LoadAndCanonicalizeMultiplayerRunSave(localPlayerId)`，原版 `RunManager.CanonicalizeSave` 只检查 `localPlayerId` 是否在 `Players` 中，不在就抛异常，原版随后把存档**改名为损坏文件**。加入方连接后，房主的 `LoadRunLobby` 检查加入方 NetId 是否在存档 `Players` 中，不在就拒绝。
- Null 平台（三端联机都不走 Steam）`NullPlatformUtilStrategy.LocalPlayerId` 默认是 `1`。

**规则**：

1. **playerId**：每台设备一个持久化随机 ID，范围 `[2, 2^63-1]`（**不能是 0 或 1**，1 留给房主），十进制字符串保存。Android `settings.save` 的 `lan_player_id`（开启「自定义玩家 ID」时用 `lan_custom_player_id`：纯数字且 >1 直接用，否则取 UTF-8 的 SHA-256 前 8 字节大端 & `0x7FFF…`，≤1 时 +2）；iPad `config.json` 的 `network.playerId`；Windows 启动器配置。读到 0/1/非法值时重新生成。复制配置到新设备必须重新生成。
2. **线上 NetId**：房主 = `1`（原版固定）；加入方 = 本机 `playerId`（`ENetClientConnectionInitializer(playerId, host, port)`）。局域网直连与联机小屋相同。
3. **判定本机在存档里的身份**（续局、放弃存档等所有调用 `LoadAndCanonicalizeMultiplayerRunSave` 的地方都先做这一步，用结果替换传入的 `localPlayerId`）：
   - 存档 `Players` 含本机 `playerId` → 本机是**加入方**，身份 ID = `playerId`；
   - 否则含 `1` → 本机是**房主**，身份 ID = `1`；
   - 否则 → **身份不匹配**：不调用原版（避免存档被改名为损坏），返回 `ValidationFailed`，写日志 `[OnlineRoom] 续局身份不匹配: save=<ID 列表> local=<playerId>`，提示「这个多人存档不属于当前玩家 ID。请恢复创建存档时的玩家 ID，存档已保留未改动。」
   - 先查 `playerId` 再查 `1`，因为加入方本地存档里也有 `1`（原房主）；只查 `1` 会让原加入方顶替房主的角色。
4. **开房续局**（`type=host` 且有多人存档，或游戏内「继续」）：只有身份是**房主**时才允许用 ENet 开房续局。身份是加入方时拒绝开房，提示「这个多人存档里你是加入方，只能由原房主开房续局。请让原房主创建房间后加入。」并写日志；身份不匹配时按上一条提示。两种情况都**不修改、不删除、不改名**存档。
5. **加入续局**：加入方照常用本机 `playerId` 加入；房主端原版 `LoadRunLobby` 会拒绝不在存档里的 ID，加入方看到原版错误，同时写日志。
6. **本机平台 ID**（`NullPlatformUtilStrategy.GetLocalPlayerId`）不要求三端一致：Android 保持原版 `1`（除非用户开「自定义平台玩家 ID」），iPad 返回 `playerId` 但把存档账号目录固定为 `default/1`。续局只依赖第 3 条的判定，不依赖平台 ID。
7. 存档里的 NetId 不随设备改写；换设备续局需要把原设备的 `playerId` 一起迁移（Android 的整机备份会带上 `settings.save`）。

**跨端结果**：同一局的房主（任意平台，存档里为 1）可以在任意时候用自己的设备开房续局，原加入方（任意平台）用各自 `playerId` 加入即可；原加入方开房会被拒绝并提示。三端实现上述 1–5 条后即可互相续局。

| 端 | 现状（2026-11-09） | 需要改的 |
| --- | --- | --- |
| Android | 房主 1、加入方 `lan_player_id`（或自定义玩家 ID）。原来续局判定先查平台 ID（=1），原加入方开房会顶替房主角色 | **已按第 3、4 条实现**（port-mod `LanMultiplayerPatches` + `OnlineRoomProtocol.ResolveSaveRole`，所有 target 使用新顺序；v0.107.1 / v0.111.0 身份不匹配时直接返回 `ValidationFailed`，其他旧 target 仍交给原版）。启动器写入的 `playerId` 由 `OnlineIdentity` 读同一个 `lan_player_id`。 |
| Windows | 房主 1、加入方启动器 playerId | 续局判定按第 3、4 条实现；Steam 已初始化时平台 ID 是 SteamID，不能直接传给原版 |
| iPad | 房主 1（ENet 固定）、加入方 `network.playerId`；`CanonicalizePrefix` 强制用 `playerId`，**房主续自己开的局会被拒绝** | 按第 3 条改为「先 `playerId` 后 `1`」，`LoadedHostPrefix` 按第 4 条只允许身份为房主 |

## 4. 联机组件自动安装

| 端 | 组件 | 自动安装方式 |
| --- | --- | --- |
| Windows | `STS2CottageOnline`（按游戏版本分别构建 v0.107.1 / v0.111.0，引用 `port-mod/refs/original-v0.107.1`、`original-v0.111.0`） | 开房/加入前：检测当前启动配置的游戏版本 → 复制对应构建到 `<游戏目录>/mods/STS2CottageOnline/`（内容相同则不动）→ 在当前账号 `settings.save` 启用它、禁用 Reforged/旧 LAN MOD → 写 pending-action → 启动游戏。游戏版本不在支持列表时直接告诉用户。只装它一个 MOD 时保持原版存档目录（不切到 `modded/`）。 |
| Android | 兼容包内置 `RemoteRoomPatches`（v0.107.1 与 v0.111.0 target） | 已内置。支持联机的 target 在兼容包 manifest 的 `targets[].capabilities` 声明 `online_rooms`；当前启动配置的兼容包关闭、或 target 没有该能力时，联机小屋显示提示并阻止开房/加入，引导到「版本 → 兼容包」更新。 |
| iPad | 静态织入 | 已内置。 |

## 5. 日志规范

### 5.1 启动器日志

- 每端一个滚动日志文件：`launcher.log`，单文件上限 2 MiB，保留 5 个（`launcher.1.log` …）。
  - Android：`<files>/logs/launcher.log`（`LauncherLog`），日志查看器「启动器/联机」来源列出。
  - Windows：`%APPDATA%/STS2 Cottage Launcher/logs/`。
  - iPad：`Documents/Launcher/logs/`。
- 行格式（三端相同，方便合并排查）：

```
2026-11-09T12:34:56.789+08:00 E [online] 创建房间失败: <原文> | <异常类型>: <消息>
    at ...（堆栈，多行缩进）
```

  级别 `D/I/W/E`；标签固定集合：`app`、`launch`、`online`、`frp`、`mods`、`saves`、`cloud`、`workshop`、`nexus`、`update`、`ui`。
- **硬性要求**：任何 catch 到的异常、任何展示给用户的错误提示，都必须先写一条 `E`（或可预期的 `W`）日志，带原始异常和堆栈；不允许静默吞异常（确实需要忽略的，写 `D` 并注释原因）。未捕获异常（Electron 主进程/渲染进程、Java 线程、ObjC 异常/信号）全部记录。
- 日志里不得出现：frp 令牌、Steam 凭据/refresh token、WebDAV 密码、Nexus API key、AI 接口 key。写日志的公共函数统一做脱敏。
  - Android 参考实现：读到这些值时登记为精确脱敏串（`LauncherLog.registerSecret`），再加正则兜底（`token/password/api_key/secret/authorization = 值`、`Bearer/Basic …`、JWT、`sk-…`、URL 里的 `user:pass@`），统一替换为 `***`。

### 5.2 游戏内联机组件日志

- 统一前缀 `[OnlineRoom]`，写进游戏自己的日志（Godot `godot.log` / Android 运行日志）。
- 另外追加一份到 `user://launcher/online-game.log`（同行格式，标签 `online`；超过 2 MiB 时转存为 `online-game.1.log`），这样启动器不必解析整个游戏日志就能展示联机相关报错。Android：`<files>/launcher/online-game.log`。
- 记录：读取/丢弃指令、开房端口与结果、加入地址、握手失败原因（原版错误码原文）、断线原因、续局身份不匹配。

### 5.3 frp 日志

frp 自身日志 `frpc.log`（级别 info，保留 1 天），由启动器纳入导出。Android 写在 `<files>/logs/frpc.log`。

### 5.4 崩溃与异常退出

- **以 Android 现有实现为准**（2026-11-09 核对后改写本条）：
  - 「启动标记」：游戏 Activity 创建时写入（Android `StartupHealthTracker`：开始时间、渲染器），**游戏引擎主循环开始运行时清除**。因此它检测的是「游戏没能启动到主循环」（启动阶段崩溃、黑屏卡死后被杀），不是游戏进行中的任意退出——移动端游戏在后台被系统回收很常见，按「正常退出才删除」会大量误报。
  - 下次打开启动器发现残留标记 → 写一条 `W [launch]` 日志并弹出「上次游戏异常退出」，提供「查看 / 导出日志」直接进入日志页。
  - 进程内未捕获异常（Android 的 Java 异常）先写 `E [app]` 日志，再进入崩溃页（Android `Sts2CrashActivity`：摘要、渲染器/系统/版本、复制详情、重试或回到启动器）。
  - Windows / iPad 可以用 `launch-marker.json` 文件实现同一语义：启动游戏前写（启动时间、版本、启动配置、MOD 列表），**确认游戏已进入主菜单或游戏进程正常退出时删除**；能拿到游戏进程退出码的平台（Windows）可以额外把非零退出码记为异常退出。
- 启动器自身崩溃同样记录并在下次打开提示。

### 5.5 日志查看与一键导出

- 启动器内「日志」页面：列出启动器日志、游戏日志（最近几次）、联机日志、frp 日志，可查看、搜索、按级别过滤（对齐 Android `LogViewerActivity` / `LogFileViewerActivity`）。
- 「导出日志」：打包 `sts2-logs-<platform>-<yyyyMMdd-HHmmss>.zip`，内容：上述日志、`diagnostics.json`（平台、系统版本、设备型号、启动器版本、游戏版本、启动配置、已启用 MOD 列表、联机配置中非敏感字段）、脱敏后的启动器配置。Android 用分享面板，Windows 用保存对话框，iPad 用分享面板。
  - Android 参考实现（`LogExportBundle`）：日志页「一键打包」= 最新 `godot.log` / `sts2.log` + `launcher*.log` + `online-game*.log` + `frpc.log` + `diagnostics.json`。`diagnostics.json` 字段：`platform`、`generatedAt`、`osVersion`、`deviceModel`、`abis`、`launcherVersion`、`lastStartupMarker`、`launchProfile{profileId,gameVersion,compatEnabled,compatPack,compatVersion,compatOnlineRooms}`、`mods{loadingEnabled,enabled[],disabled[]}`（`id@version`）、`online{configured,server,nickname,playerId,hostTokenSaved,compatProblem}`、`settings`（`settings.save` 副本，键名含 token/password/secret/api_key/cookie/credential 的值替换为 `***`）。三端字段名保持一致，平台没有的字段可省略。
- 日志 AI 分析（Android `loganalysis/` + `llm/`）三端对齐，接口 key 只存本机。

## 6. 功能对齐清单（以 Android 为准）

| 功能 | Android 参考代码 | Windows | iPad |
| --- | --- | --- | --- |
| 主题/主页/导航 | `CottageHomeStage`、`CottageTheme`、`doc/architecture/launcher-theme.md` | 已有 | 已有 |
| 本地 MOD 管理（导入、启停、依赖/顺序检查、自动修复顺序） | `ModsPage`、`ModInstallStore` | 已有，核对差异 | 已有（只能启用资源 PCK，DLL 归档，平台限制） |
| 存档管理、快照、导入导出、整机数据备份 | `LocalSaveSnapshotManager`、`full_data_backup_*` | 已完成：快照 + 整机数据备份 / 恢复（2026-11-09） | 已有备份，补快照/启动前快照 |
| 启动配置（多配置、额外参数、版本信息） | `LaunchProfileManager`、`GameVersionManagerPage` | 已有 | 补 |
| 联机小屋（在线房间、局域网直连、昵称、令牌） | `NetworkPage`、`OnlineRoomService` | 已完成：小屋组件 v0.107.1 / v0.111.0、pending-action v1、房间卡 platform、§3.4 续局判定（真机联机未验证） | 已有，补局域网直连、令牌输入、平台字段 |
| 日志查看、崩溃报告、导出、AI 分析 | `LogViewerActivity`、`LogFileViewerActivity`、`Sts2CrashActivity`、`loganalysis/`、`llm/` | 已完成：launcher.log、日志页、崩溃提示、导出 zip、AI 分析 | 新增 |
| Steam 创意工坊浏览/详情/图片查看/下载安装 | `SteamWorkshopActivity`、`steam/` | 部分完成：浏览 / 详情 / 截图 / 前置；安装来自 Steam 客户端订阅内容或直链。未做 SteamPipe 匿名下载与补给站 | 新增（下载后按 iOS 规则：PCK 可启用，DLL 归档） |
| Steam 账号登录 | `SteamAccountActivity`、`steam/auth` | 未做（工坊用 Steam 客户端订阅，Steam 云用「通过 Steam 启动」） | 同左 |
| 云存档：WebDAV、Steam 云，启动前后自动同步与冲突处理 | `webdav/`、`steam/cloud` | WebDAV 已完成（启动前拉取、干净退出后上传、冲突）；直接启动时的 Steam 云同步未做 | 新增 |
| Nexus Mods 商店 | `NexusModsStoreActivity`、`NexusModsApiClient` | 已完成（含 NXM 链接下载） | 新增（同 iOS MOD 规则） |
| 启动器更新检查 | `ExtraSettingsUpdateChecker` | 已完成（只提示） | 新增（只提示，不自动安装） |
| 文件浏览/文本编辑（存档与配置） | `FileBrowserActivity`、`TextEditorActivity` | 已完成（三个根目录 + 内置文本编辑） | 新增 |
| 设置项（语言、渲染器、启动后行为、日志等级等） | `SettingsPage`、`ExtraSettings*` | 未逐项核对 | 核对补齐 |

**不适用（平台本身没有）**：Android 的 payload 导入/游戏本体版本管理、兼容包管理、离线引导、内置键盘/悬浮键盘/悬浮鼠标、高刷新率、Logcat 采集；Windows 不需要；iPad 中与触控/键盘相关的部分按 iPad 实际需要评估，不强求。

### 6.1 Windows 实现状态（2026-11-09）

- 细节见 [`windows/README.md`](../../windows/README.md)。日志：`%APPDATA%/STS2 Cottage Launcher/logs/launcher.log`，`diagnostics.json` 使用 §5.5 同名字段（Windows 额外信息在 `windows` 下）；启动标记在游戏进程退出码为 0 时删除、非 0 记为异常退出（通过 Steam 启动时拿不到进程，不做检测）。
- 联机：`STS2CottageOnline` 已对 v0.107.1（macOS Steam 版托管程序集）与 v0.111.0（`sts2-ios/game-refs`）原版程序集编译通过；pending-action / 设置启用 / Reforged 禁用流程在 macOS 上用伪造游戏目录跑通。**未验证**：真机 Windows 上游戏内自动开房 / 加入、与 Android / iPad 跨端联机、续局。
- 未做：直接启动时的 Steam 云同步与 Steam 账号登录、创意工坊 SteamPipe 匿名下载 / 尖塔补给站 / 兼容访问、新页面的英文文案、设置项逐项核对。

## 7. 验收

- 每端：单元测试覆盖房间卡解析、pending-action 读写/过期、日志脱敏与滚动、导出包内容。
- 跨端：同一 frp 服务器上 Windows↔Android（v0.107.1）、Windows↔Android↔iPad（v0.111.0）互相开房/加入、出牌同步、续局；故意制造版本不一致、令牌错误、端口占用、服务器不可达，确认每种情况都有用户可读提示 + 日志。真机验收结果写回各端文档，未实测的明确写「未验证」。
