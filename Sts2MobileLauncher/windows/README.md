# STS2 小屋启动器（Windows）

杀戮尖塔 2 的 Windows 启动器，与 Android、iPad 启动器共用同一套「喵喵零和小鱼的小屋」前端：同一张主页插画、相同的热区坐标、夜间小屋配色、描边标题和代码绘制的吉祥物。布局规则见 [`doc/architecture/launcher-theme.md`](../doc/architecture/launcher-theme.md)。

Windows 直接运行 PC 原版游戏，所以这里**没有** Android 兼容包、payload 导入或 Godot/Mono runtime；启动器只负责找到游戏、管理 MOD 与存档，然后启动游戏。

## 功能

| 页面 | 内容 |
| --- | --- |
| 回到小屋 | 整幅插画主页，插画里的「存档管理 / 本地 MOD / 联机小屋 / 设置 / 开始游戏」是真实按钮；未找到游戏时开始按钮上方显示提示。 |
| 游戏管理 | 明信片插画 + 吉祥物 +「进屋开玩」；MOD / 存档状态卡；打开游戏/MOD/存档目录、存档快照、启动配置、Steam 校验文件、日志页与文件管理。 |
| 本地 MOD | 扫描 `<游戏目录>/mods/`；总开关和单个开关写入当前存档账号 `settings.save` 的 `mod_settings`（与 Android 同一协议）；导入 ZIP / 文件夹（Zip Slip 防护、同 ID 冲突与文件覆盖确认、`mod_manifest.json` → `<ModId>.json` 别名）；缺依赖、依赖未启用、加载顺序、缺 DLL/PCK、重复 ID、最低游戏版本检查，以及「自动修复加载顺序」。页内有「Steam 创意工坊」「Nexus Mods」入口。 |
| Steam 创意工坊 | 匿名浏览公开 Workshop（热门 / 最新发布 / 最近更新 / 最多订阅 + 时间范围，同 Android），粘贴条目 ID / 链接直接打开；详情含截图（大图查看）、标签、前置 MOD 与安装状态。安装方式见下文。「已下载」列表、检查更新、删除记录（可连 MOD 一起删）。 |
| Nexus Mods | 保存 Personal API Key（本机加密）后浏览热门 / 最新 / 近期更新、搜索、按链接 / ID 查询；文件列表下载 ZIP 导入 `mods/`；非 Premium 时粘贴网页「Mod Manager Download」的 `nxm://` 链接下载。 |
| 版本管理 | 启动配置 = 游戏目录：自动检测 Steam 库（注册表 + `libraryfolders.vdf` + `appmanifest_2868840.acf`），也可手动添加多个目录；显示 `release_info.json` 版本、分支与 `sts2.dll` SHA-256；每个配置可选通过 Steam 启动或直接运行 exe，并带自己的额外参数。 |
| 联机小屋 | 与 Android / iPad 互通的在线房间：设置昵称、创建房间（经内置 frp 客户端发布到联机服务器）、在线房间列表一键加入（显示房主平台）；另有局域网直连。启动器按游戏版本自动安装并启用小屋联机组件，游戏到主菜单后自动开房 / 加入。 |
| 日志 | 列出启动器日志、游戏日志（最近 6 个）、联机组件日志、frp 日志与崩溃报告；查看尾部 1 MB、搜索、按 E/W/I/D 过滤、复制；「导出日志」保存 `sts2-logs-windows-<时间>.zip`。 |
| 日志分析（AI） | 日志页「AI 分析」：自配 OpenAI 兼容服务（Base URL / API Key 加密保存 / Model / Thinking effort），勾选 1–3 个日志，模型只能用只读工具 `read_lines` / `search_logs` 按需读取，不上传全文；首次发送前征求同意，每题最多 24 轮，对话只在内存（对齐 Android `loganalysis/` + `llm/`）。 |
| 设置 | 画面（窗口模式、渲染器）/ 操作（启动后行为、语言）/ 存档（存档目录、账号、云存档入口、启动前快照、保留数量、完整数据备份、快照列表与恢复）/ 系统（日志等级 → `-log` 参数、额外参数、文件管理、联机说明、数据目录）。 |
| 云存档 | WebDAV：地址 / 用户名 / 密码（加密）/ 槽位，模式「关闭 / 仅手动 / 启动前拉取 / 启动前拉取 + 干净退出后上传」，刷新清单、拉取、上传、强制上传，冲突时选保留本地或云端；规则同 Android `webdav/`。Steam Cloud 见下文。 |
| 文件管理 | 浏览游戏存档、启动器数据、当前游戏 MOD 三个目录；文本文件（≤ 2 MiB）内置编辑，`.save` / `.json` 保存前检查 JSON，编辑期间文件被改写时拒绝覆盖，首次保存留 `.launcher-backup`。 |
| 关于 | 版本与说明；检查启动器更新（GitHub Releases，只看带 `sts2-cottage-launcher-*-win-*` 产物的版本；启动时每天最多自动检查一次，可关闭；只提示并打开下载页）。 |

宽屏（宽 ≥ 720 且横向）显示左侧插画侧栏；宽高比 ≥ 1.25 时「回到小屋」显示整幅插画；窄窗口改为顶部胶囊标签，与 Android 手机竖屏一致。

## 联机小屋

与 Android / iPad 启动器同一套协议（[`doc/architecture/cross-platform-parity.md`](../doc/architecture/cross-platform-parity.md) §3、§4）。PC 原版多人菜单只有 Steam 好友联机，游戏内联机由启动器自带的「小屋联机组件」`STS2CottageOnline`（[`online-mod/`](online-mod/)，`affects_gameplay: false`）实现：只用游戏自带的 ENet 传输与原版 `JoinFlow` 握手，不新增网络消息、不放宽版本 / ModelDb 校验。

点「创建房间 / 加入 / 局域网开房 / 局域网加入」时启动器会：

1. 检查当前启动配置的游戏版本：组件分别按 **v0.107.1**（Steam 当前公开版）和 **v0.111.0**（beta，三端互通的版本）的原版程序集构建，其他版本直接提示不支持。
2. 把对应版本的构建复制到 `<游戏目录>/mods/STS2CottageOnline/`（内容相同则不动，切换版本时替换）。
3. 在游戏实际使用的存档账号（直接启动用 `default/<n>`，Steam 启动用 `steam/<id>`）的 `settings.save` 里启用它，并禁用 `LAN Multiplayer: Reforged`、旧 `SlayTheSpire2.LAN.Multiplayer`（只改开关，不删文件，写日志）。MOD 总开关原本关着时会打开它并把其他 MOD 设为禁用，避免双方玩法 MOD 不一致；只装组件时游戏仍用原版存档目录（不切到 `modded/`）。
4. 写一次性指令 `%APPDATA%\SlayTheSpire2\launcher\pending-action.json`（v1：`v/type/created/online/host/port/nickname/playerId`），然后启动游戏。组件在主菜单就绪约 0.6 s 后读取并删除指令：`host` 在 UDP 33771 开房（有多人存档时按原版「继续」续局），`join` 用本机稳定 `playerId` 走原版 `NMainMenu.JoinGame`。超过 600 s 的指令丢弃并写日志；解析失败、未知类型、地址非法会在游戏里弹中文错误框并写日志。启动器每次打开时清掉遗留指令。

组件日志前缀 `[OnlineRoom]`，同时追加到 `%APPDATA%\SlayTheSpire2\launcher\online-game.log`（启动器「日志」页可看）：读取 / 丢弃指令、开房端口与结果、加入地址、续局身份不匹配，以及联机期间原版错误弹窗的原文（握手失败、断线原因）。

身份（规范 §3.4）：每台电脑一个持久化随机 63 位 `playerId`（启动器配置，范围 [2, 2^63-1]）。房主 NetId 恒为 1（原版 ENetHost），加入方 NetId = `playerId`。开房续局前先读多人存档的 `Players[].NetId`：含本机 `playerId` → 本机当时是加入方，拒绝并提示「只能由原房主开房续局」；否则含 1 → 本机是房主，按原版「继续」续局；都不含 → 身份不匹配，拒绝并提示。拒绝时不调用原版 canonicalization（避免存档被改名成损坏文件），并写日志。

在线房间：服务器上 20 个槽位，槽位 i 把本机 UDP 33771 映射到服务器 UDP `33771+i`，房间卡 JSON（含 `platform: "windows"`）发布在 TCP `34771+i`；列表显示房主平台，版本不同时禁用加入。frp 客户端是 `frp-helper/`（官方 frp v0.71.1 库编成的 `sts2-frpc.exe`），由启动器作为子进程运行，stdin 关闭即退出，日志 `frp/frpc.log`。当房主时“启动后关闭启动器”会改为最小化，退出游戏（直接运行 exe 时）或点“关闭房间”即关闭隧道。公开构建只内嵌 FRP 服务器地址与端口，不内嵌令牌；加入在线房间无需令牌，房主在「联机小屋 → 输入令牌」输入后才可开在线房间。令牌只在本次启动器进程内保留，不写进启动器配置、日志或导出包；创建隧道时会在本机用户数据目录 `frp/frpc.toml` 写入令牌供 frp 客户端读取，不要共享这个文件。`prepare-assets` 从 `.env` 的 `STS2_FRP_SERVER` / `STS2_FRP_SERVER_PORT` 生成 ignored 的 `assets/generated/online.json`；未配置服务器时仍可局域网直连。

构建：

- `tools/windows/build-frp-helper.sh`（Go）→ `resources/frp/sts2-frpc.exe`。
- `tools/windows/build-online-mod.sh`（.NET 9）→ `resources/online-mod/v0.107.1/STS2CottageOnline/` 与 `resources/online-mod/v0.111.0/STS2CottageOnline/`。引用目录：`STS2_ORIGINAL_V1071_REFERENCE_DIR` / `STS2_ORIGINAL_V1110_REFERENCE_DIR`（含 `sts2.dll`、`GodotSharp.dll`、`0Harmony.dll`；macOS Steam 版 `SlayTheSpire2.app/Contents/Resources/data_sts2_macos_arm64` 的托管程序集也可以），否则找 `port-mod/refs/original-v0.107.1`、`original-v0.111.0`。缺某个版本的引用时跳过该版本（`STS2_REQUIRE_ALL_ONLINE_MODS=1` 时报错）；`STS2_ONLINE_MOD_VERSION` 只构建一个版本。
- 两者由 `tools/package/build_windows_launcher.sh` 自动调用并作为 extraResources 打包。CI 只构建 frp 助手（没有原版程序集），CI 包的联机页会提示缺少联机组件。只有 frp 助手缺失时仍可加入在线房间或局域网直连，不能创建在线房间。

未实测：真机 Windows↔Android / iPad 跨端开房、加入、出牌同步与续局（见规范 §7）。

## 日志与崩溃

规范见 [`doc/architecture/cross-platform-parity.md`](../doc/architecture/cross-platform-parity.md) §5。

- 启动器日志 `%APPDATA%\STS2 Cottage Launcher\logs\launcher.log`：单文件 2 MiB，滚动保留 `launcher.1.log` … `launcher.4.log`（共 5 个）。行格式 `2026-11-09T12:34:56.789+08:00 E [online] 消息 | 异常类型: 消息` + 缩进堆栈，标签 `app/launch/online/frp/mods/saves/cloud/workshop/nexus/update/ui`。设置里日志等级为 debug / very_debug 时额外写 `D` 行。
- 写入前统一脱敏：已登记的密钥原文（FRP 令牌、WebDAV 密码、Nexus / AI key 等）以及 `token=…`、`"password": "…"`、`Authorization: Bearer …`、URL 里的账号密码。
- 主进程与渲染进程的未捕获异常、IPC 调用失败、界面上显示的每条错误提示都会写日志；可预期的用户错误记 `W`，其他记 `E` 并带堆栈。
- 启动游戏（直接运行 exe）前写 `launch-marker.json`（时间、游戏版本、启动配置、参数、已启用 MOD、进程号），正常退出（退出码 0）时删除；非 0 退出码立即记崩溃报告并弹出「上次游戏异常退出」，可查看 / 导出日志。启动器自己没有正常退出（`launcher-session.json` 残留）或游戏运行中启动器崩溃，下次打开时同样提示。启动器先于游戏关闭时只能事后看进程是否还在，不判为崩溃。通过 Steam 启动拿不到游戏进程，不做崩溃检测。崩溃报告在 `crash-reports\`，最多 20 份。
- 「导出日志」zip：`logs/<来源>/…`（全部经过脱敏，单个文件超过 16 MiB 只取尾部）、`diagnostics.json`（平台、系统版本、启动器 / Electron 版本、游戏版本与 sts2.dll SHA、启动配置、设置、存档账号、已启用 MOD、联机非敏感字段、崩溃报告列表）、`launcher-config.json`（键名像密钥的字段替换为 `***`）。
- 开发调试：`STS2_LAUNCHER_DATA_DIR=<目录>` 使用独立数据目录；再加 `STS2_LAUNCHER_SNAPSHOT_DIR=<目录> STS2_LAUNCHER_SNAPSHOT_TABS=logs,network` 会依次打开这些页面截图后退出，可在 macOS / Linux 上检查界面。

## 创意工坊、云存档与备份

- **创意工坊安装**：PC 原版只在通过 Steam 运行时加载创意工坊订阅，直接运行 exe 时不会加载。启动器的安装方式是：详情页点「在 Steam 订阅」（打开 Steam 客户端的条目页面）→ Steam 下载到 `<Steam 库>/steamapps/workshop/content/2868840/<id>/` → 点「安装到 MOD 目录」复制进 `<游戏目录>/mods/<id>/`（走本地导入的同 ID 冲突 / 覆盖确认）。带旧式直链 `file_url` 的条目可直接下载。「已下载」页还会列出 Steam 已订阅但没装进 mods 的条目。下载记录在 `workshop/library.json`，按远端更新时间检查更新。
  - 未实现：Android 的 SteamPipe UGC 匿名下载 / 尖塔补给站（需要 Steam manifest / chunk 协议与 CM 登录）、已登录账号的「已订阅 MOD」云端列表、「兼容访问」（rmbgame 转发需要自定义 TLS SNI）。国内直连 `steamcommunity.com` 常被重置，浏览需要加速器；按 ID / 链接打开只需要 `api.steampowered.com`。
- **WebDAV**：远端目录 `<地址>/SlayTheSpire2/saves/<槽位>/`（槽位留空用启动配置 ID），`.sts2re/manifest.json` 记 SHA-1；只同步白名单存档（`profile.save`、`profileN/saves/` 下的 progress / prefs / current_run / current_run_mp 及 `.backup`、`history/*.run`，以及 `modded/` 下同名文件；`settings.save` 需手动开启），不做远端删除。作用于游戏实际使用的存档账号（直接启动 `default/<n>`，Steam 启动 `steam/<id>`）。baseline 只记录双方确认相同的文件；拉取前把账号目录打包到 `webdav/cloud/<槽位>/backups/`（保留 10 份）。启动游戏（含联机启动）前按模式拉取；游戏退出码为 0 时先建 `clean-exit` 快照，「完整自动」模式再自动上传。
- **Steam Cloud**：启动配置开启「通过 Steam 启动」时由 Steam 客户端同步。直接启动时由启动器同步 Steam 云**尚未实现**（Android 用 JavaSteam 的 CM 登录 + RemoteStorage 协议，Windows 端暂无对应实现）。
- **完整数据备份**：`sts2-full-backup-windows-<时间>.zip` = `saves/`（游戏 user:// 目录，跳过 logs / shader_cache / launcher）+ `launcher/launcher.json`（含联机 playerId）+ 可选 `mods/` + `backup.json`。不含 `secrets.json`（DPAPI 只在本机可解）和 FRP 令牌。恢复前自动把当前数据备份到 `full-backups/`，存档目录整体替换（失败回滚），启动器设置合并（保留本机启动配置列表），MOD 按路径覆盖复制。
- **凭据**：AI 接口 key、WebDAV 密码、Nexus API key 用 Electron `safeStorage`（Windows DPAPI）加密存在 `secrets.json`；加密不可用时拒绝保存，不退回明文；值不进日志、导出和渲染进程。
- **界面语言**：新增页面（日志、AI 分析、创意工坊、云存档、Nexus、文件管理、备份、更新）目前只有中文文案，英文界面会回退到中文。

## 数据位置

- 启动器配置、存档快照、导入缓存：`%APPDATA%\STS2 Cottage Launcher\`（设置 → 系统 → 启动器数据目录）：`launcher.json`、`secrets.json`、`logs/`、`crash-reports/`、`save-snapshots/`、`webdav/cloud/`、`workshop/`、`full-backups/`、`frp/`。
- 游戏存档：默认 `%APPDATA%\SlayTheSpire2\`，账号目录为含 `settings.save` 的子目录（如 `steam\<SteamID64>`）。第一次修改 `settings.save` 前会留一份 `settings.save.launcher-backup`。
- 快照：`save-snapshots\<账号>\<时间>-<原因>.zip`；只自动清理「启动前 / 恢复前」快照，手动快照不删除。恢复前先自动备份当前存档，失败时回滚。

## 开发与打包

需要 Node.js 22。

```bash
cd windows
npm ci
npm test          # 后端单元测试（VDF、启动参数、MOD、导入、快照、联机、日志、AI 工具、创意工坊、WebDAV、Nexus、更新、备份、文件）
npm start         # 本地运行（Linux/macOS 也能跑界面，便于调试）
```

构建：

```bash
tools/package/build_windows_launcher.sh
```

- 输出便携版 `dist/windows/sts2-cottage-launcher-<version>-win-x64.zip`（解压后运行 `STS2 Cottage Launcher.exe`）。
- 在 Windows / macOS 上同时输出 NSIS 安装包 `sts2-cottage-launcher-<version>-win-x64.exe`（Linux 需要 Wine）：`npm run dist`；也可以手动运行 GitHub Actions 的 **Windows launcher** 工作流，从产物下载 zip 与安装包。
- 自动检测 Steam 库只用于定位已安装的游戏文件。新启动配置默认直接运行 `SlayTheSpire2.exe --force-steam off`，不需要登录 Steam；旧版保存的 Steam 启动配置首次升级时会切换为直接启动，并立即保存迁移后的配置；关闭升级前已经运行的旧版启动器，再打开新版使迁移生效。若需要 Steam 云存档或原版联机，可在启动配置中手动开启「通过 Steam 启动」。本启动器不会修改游戏文件或 Steam 账号。
- 插画、图标与 Material Symbols 字体只在仓库保留一份（`android/res/`、`doc/images/`），`npm run prepare-assets` 会复制到 ignored 的 `windows/assets/generated/`。

当前未做代码签名，首次运行时 Windows SmartScreen 可能提示未知发布者。
