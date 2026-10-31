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
| 联机小屋 | 与 Android / iPad 互通的在线房间：设置昵称、创建房间（经内置 frp 客户端发布到联机服务器，直接进入选角色或续上多人存档）、在线房间列表一键加入；另有局域网直连（本机开房并列出局域网 IP / 填 IP 和端口加入）。 |
| 设置 | 画面（窗口模式、渲染器）/ 操作（启动后行为、语言）/ 存档（存档目录、账号、启动前快照、保留数量、快照列表与恢复）/ 系统（日志等级 → `-log` 参数、额外参数、联机说明、数据目录）。 |
| 关于 | 版本与说明。 |

宽屏（宽 ≥ 720 且横向）显示左侧插画侧栏；宽高比 ≥ 1.25 时「回到小屋」显示整幅插画；窄窗口改为顶部胶囊标签，与 Android 手机竖屏一致。

## 联机小屋

PC 原版的多人菜单只有 Steam 好友联机。启动器在联机前把「小屋联机组件」MOD（`online-mod/`，`affects_gameplay: false`）装到 `<游戏目录>/mods/STS2CottageOnline/` 并在 `settings.save` 里启用它（MOD 总开关原本关着时，会打开总开关并把其他 MOD 设为禁用），然后把一次性指令写到 `%APPDATA%\SlayTheSpire2\launcher\pending-action.json` 再启动游戏。组件在主菜单读取并删除指令（超过 10 分钟的指令丢弃）：

- `host`：用游戏自带 ENet 在 UDP 33771 开房（房主身份 1，与原版 `fastmp` 相同），有多人存档时续局；存档里没有房主身份 1（Steam 联机或加入别人时产生的存档）就提示并拒绝，避免原版把身份不符的存档改名为损坏文件。
- `join`：原版 `NMainMenu.JoinGame(ENetClientConnectionInitializer)`，联机身份是启动器保存的随机 ID（`launcher.json` 的 `online.playerId`）。
- 只装了这个组件时保持原存档目录（原版装任何 MOD 都会切到 `modded/`）；不改消息、序列化、版本或 ModelDb 校验，Steam 好友联机照常。

在线房间与 Android / iPad 同一协议：服务器上 20 个槽位，槽位 i 把本机 UDP 33771 映射到服务器 UDP `33771+i`，房间卡 JSON 发布在 TCP `34771+i`。frp 客户端是 `frp-helper/`（官方 frp v0.71.1 库编成的 `sts2-frpc.exe`），由启动器作为子进程运行，stdin 关闭即退出；当房主时“启动后关闭启动器”会改为最小化，退出游戏（直接运行 exe 时）或点“关闭房间”即关闭隧道。服务器地址/端口/令牌由 `.env` 的 `STS2_FRP_SERVER` / `STS2_FRP_SERVER_PORT` / `STS2_FRP_TOKEN` 在 `prepare-assets` 时写入 ignored 的 `assets/generated/online.json`。

构建：`tools/windows/build-frp-helper.sh`（Go）→ `resources/frp/sts2-frpc.exe`；`tools/windows/build-online-mod.sh`（.NET 9 + `STS2_WINDOWS_MOD_REFERENCE_DIR` 或 `STS2_ORIGINAL_V1110_REFERENCE_DIR` 的原版程序集）→ `resources/online-mod/STS2CottageOnline/`。两者由 `tools/package/build_windows_launcher.sh` 自动调用并作为 extraResources 打包；CI 只构建 frp 助手（没有原版程序集），因此 CI 包的联机小屋会提示缺少组件。组件按 v0.111.0 编译，双方游戏版本须一致。

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
- 插画、图标与 Material Symbols 字体只在仓库保留一份（`android/res/`、`doc/images/`），`npm run prepare-assets` 会复制到 ignored 的 `windows/assets/generated/`。

当前未做代码签名，首次运行时 Windows SmartScreen 可能提示未知发布者。
