# STS2 小屋启动器（Windows）

杀戮尖塔 2 的 Windows 启动器，与 Android、iPad 启动器共用同一套「喵喵零和小鱼的小屋」前端：同一张主页插画、相同的热区坐标、夜间小屋配色、描边标题和代码绘制的吉祥物。布局规则见 [`doc/architecture/launcher-theme.md`](../doc/architecture/launcher-theme.md)。

Windows 直接运行 PC 原版游戏，所以这里**没有** Android 兼容包、payload 导入或 Godot/Mono runtime；启动器只负责找到游戏、管理 MOD 与存档，然后启动游戏。

## 功能

| 页面 | 内容 |
| --- | --- |
| 回到小屋 | 整幅插画主页，插画里的「存档管理 / 本地 MOD / 联机小屋 / 设置 / 开始游戏」是真实按钮；未找到游戏时开始按钮上方显示提示。 |
| 游戏管理 | 明信片插画 + 吉祥物 +「进屋开玩」；MOD / 存档状态卡；打开游戏/MOD/存档目录、存档快照、启动配置、Steam 校验文件、日志与启动器数据目录。 |
| 本地 MOD | 扫描 `<游戏目录>/mods/`；总开关和单个开关写入当前存档账号 `settings.save` 的 `mod_settings`（与 Android 同一协议）；导入 ZIP / 文件夹（Zip Slip 防护、同 ID 冲突与文件覆盖确认、`mod_manifest.json` → `<ModId>.json` 别名）；缺依赖、依赖未启用、加载顺序、缺 DLL/PCK、重复 ID、最低游戏版本检查，以及「自动修复加载顺序」。 |
| 版本管理 | 启动配置 = 游戏目录：自动检测 Steam 库（注册表 + `libraryfolders.vdf` + `appmanifest_2868840.acf`），也可手动添加多个目录；显示 `release_info.json` 版本、分支与 `sts2.dll` SHA-256；每个配置可选通过 Steam 启动或直接运行 exe，并带自己的额外参数。 |
| 联机小屋 | 与 Android / iPad 互通的在线房间：设置昵称、创建房间（经内置 frp 客户端发布到联机服务器）、在线房间列表一键加入；另有局域网直连。联机本身由内置的第三方 MOD「LAN Multiplayer: Reforged」+ BaseLib 实现，启动器负责安装、启用并写入房间地址，最后在游戏「多人游戏 → 局域网」里开房 / 加入。 |
| 设置 | 画面（窗口模式、渲染器）/ 操作（启动后行为、语言）/ 存档（存档目录、账号、启动前快照、保留数量、快照列表与恢复）/ 系统（日志等级 → `-log` 参数、额外参数、联机说明、数据目录）。 |
| 关于 | 版本与说明。 |

宽屏（宽 ≥ 720 且横向）显示左侧插画侧栏；宽高比 ≥ 1.25 时「回到小屋」显示整幅插画；窄窗口改为顶部胶囊标签，与 Android 手机竖屏一致。

## 联机小屋

PC 原版的多人菜单只有 Steam 好友联机。启动器内置第三方 MOD「LAN Multiplayer: Reforged」（创意工坊 [3750220799](https://steamcommunity.com/sharedfiles/filedetails/?id=3750220799)，GPL-3.0）及其前置 BaseLib（MIT）：开房 / 加入前把两者复制到 `<游戏目录>/mods/`，在 `settings.save` 里启用它们，并禁用旧的 `SlayTheSpire2.LAN.Multiplayer` 和早期的 `STS2CottageOnline`，避免多套补丁同时生效。MOD 总开关原本关着时，会打开总开关并把其他 MOD 设为禁用，避免双方因玩法 MOD 不一致而不同步；原本已启用其他 MOD 时保持现状，界面会提示双方需要相同的 MOD。

启动器把房间参数写进 MOD 的配置文件 `<账号目录>/mods/lan_settings.json`（合并写入，保留 MOD 的其他字段），游戏启动后在游戏里完成最后一步：

- 开房：多人游戏 → 局域网 → 创建房间。端口固定 33771（`host_port`），与 frp 隧道对应；最多人数等设置由 MOD 自己的界面 / ModConfig 管理。
- 加入：多人游戏 → 加入 → 局域网地址已预填为 `IP:端口`（`ip_address`，IPv6 自动加方括号），直接加入。

MOD 没有命令行或一次性指令入口，所以启动器无法代点这两步。启用 MOD 后游戏使用 `modded` 存档目录，原版存档不会自动带入；多人存档在 `<账号>/modded/profileN/saves/current_lan_run_mp.save`，房间卡据此显示「继续存档」。内置 MOD 按 v0.107.1 原版程序集构建，只有 v0.107.1 游戏配置可联机；Android / iPad 启动器目前尚未内置这个 MOD，跨端联机暂不可用。即使能发现彼此的在线房间，也不要把发现房间视作跨端兼容性验证。Steam 好友联机不受影响。

在线房间与 Android / iPad 同一协议：服务器上 20 个槽位，槽位 i 把本机 UDP 33771 映射到服务器 UDP `33771+i`，房间卡 JSON 发布在 TCP `34771+i`。frp 客户端是 `frp-helper/`（官方 frp v0.71.1 库编成的 `sts2-frpc.exe`），由启动器作为子进程运行，stdin 关闭即退出；当房主时“启动后关闭启动器”会改为最小化，退出游戏（直接运行 exe 时）或点“关闭房间”即关闭隧道。公开构建默认不内嵌 FRP 令牌，在线房间列表与创建房间不可用，局域网直连仍可使用。自行私有构建且明确设置 `STS2_EMBED_FRP_TOKEN=1` 时，`prepare-assets` 才会从 `.env` 的 `STS2_FRP_SERVER` / `STS2_FRP_SERVER_PORT` / `STS2_FRP_TOKEN` 生成 ignored 的 `assets/generated/online.json`。不要将含令牌的构建上传公开仓库。

构建：

- `tools/windows/build-frp-helper.sh`（Go）→ `resources/frp/sts2-frpc.exe`。
- `tools/windows/build-lan-mod.sh`（.NET 9）→ `resources/online-mod/SlayTheSpire2.LAN.Multiplayer.Reforged/` 与 `resources/online-mod/BaseLib/`。脚本从 GitHub 克隆上游仓库并检出固定 commit `6623dcd793ed264ff80a5c5ac384ee94fd293110`，应用 `tools/windows/patches/` 里的启动器补丁（关闭 Steam 时玩家名回退、避免重复帧回调），复制 BaseLib（默认从 Steam 创意工坊 id 3737335127），再用 `pack-godot-pck.py` 重新打包本地化 PCK（上游 PCK 的资源路径仍是旧 MOD id）。
- 引用目录：`STS2_ORIGINAL_V1071_REFERENCE_DIR` 指向含 `sts2.dll`、`GodotSharp.dll`、`0Harmony.dll`、`Steamworks.NET.dll` 的 v0.107.1 数据目录；BaseLib 用 `STS2_BASELIB_DIR` 指定（默认按注册表找到的 Steam 目录查找）；`STS2_DOTNET` / `PYTHON_BIN` 可覆盖工具路径。
- 两者由 `tools/package/build_windows_launcher.sh` 自动调用并作为 extraResources 打包。分发包含 Reforged 二进制的 ZIP 时，须同时附带固定上游源码快照、启动器补丁、manifest 与构建脚本（便携包放在 `sources/LAN-Multiplayer-Reforged/`）。CI 只构建 frp 助手（没有原版程序集和 BaseLib），因此 CI 包会提示缺少联机 MOD。只有 frp 助手缺失时仍可加入在线房间或局域网直连，不能创建在线房间；联机 MOD 缺失时联机入口不可用。在线房间游戏版本不一致时禁用加入按钮。

## 数据位置

- 启动器配置、存档快照、导入缓存：`%APPDATA%\STS2 Cottage Launcher\`（设置 → 系统 → 启动器数据目录）。
- 游戏存档：默认 `%APPDATA%\SlayTheSpire2\`，账号目录为含 `settings.save` 的子目录（如 `steam\<SteamID64>`）。第一次修改 `settings.save` 前会留一份 `settings.save.launcher-backup`。
- 快照：`save-snapshots\<账号>\<时间>-<原因>.zip`；只自动清理「启动前 / 恢复前」快照，手动快照不删除。恢复前先自动备份当前存档，失败时回滚。

## 开发与打包

需要 Node.js 22。

```bash
cd windows
npm ci
npm test          # 后端单元测试（VDF、启动参数、MOD、导入、快照）
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
