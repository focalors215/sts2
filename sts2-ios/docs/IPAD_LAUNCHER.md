# iPad 原生启动器

冷启动先创建 UIKit 中文启动器；点“开始游戏”才进入 Godot。iPad 常规宽度使用侧栏（回到小屋、存档管理、本地 MOD、创意工坊、联机小屋、日志、设置）；紧凑宽度使用顶部标签。功能以 Android 启动器为基准，对齐清单见三端规范 §6 与下文「功能对齐」。文字随系统字号调整，使用系统颜色、SF Symbols 和至少 48 点操作按钮。

开始游戏前按应用真实 `godot_cmdline` 检查素材。当前完整包使用应用内置的 `StS2.pck`；不能仅因 Documents 没有同名文件就拒绝启动。明确配置 `--main-pack user://StS2.pck` 的瘦身包则检查 Documents 对应文件。素材必须是非空普通文件。

## 启动与生命周期

`ios-export/StS2SceneDelegate.mm` 在 Objective-C `+load` 中只替换 Godot 4.5.1 的 `GDTAppDelegateService` 启动方法：保存 service 与 launchOptions，返回 YES。Scene 自己创建启动器窗口。

开始操作检查前台状态，以 Launcher → Starting → Running / Failed 状态机防止重复启动。在主队列调用保存的原始启动 IMP，原引擎初始化、静态 mainViewController 及音频会话设置均保留。service 的 setWindow: 钩子在原代码展示窗口前绑定 UIWindowScene。成功后复用原 Godot 窗口和控制器。

前台、激活、失活、后台事件只在 Running 时转发；引擎启动前的 AppDelegate 生命周期、内存警告和退出通知由 guard 屏蔽。Scene 断开时保留游戏窗口，重新连接时复用。同一进程只允许调用引擎入口一次；失败需完全关闭应用后重开，不能卸载再初始化 Godot。原 Godot 入口内部的致命退出不能被 Objective-C 异常处理捕获。

## 存档

启动器读取 `Documents/default/1`，通过单独串行队列运行存档枚举、ZIP 导入、导出和快照。导入使用系统文件选择器；导出使用系统分享面板。导入或恢复前显示确认，数据层在替换前自动创建已有存档快照。游戏开始后不允许管理存档。

- 快照列表显示名称、时间、大小，可恢复、分享（存到“文件”）、删除。
- **启动前自动快照**（默认开）：每次从启动器进入游戏前先打包当前存档，名为「启动前自动快照」，只保留最近 5 份；可在存档页关闭。
- **WebDAV 云存档**（`STS2WebDavSync`、`STS2CloudSaveViewController`）：远端 `SlayTheSpire2/saves/<槽位>/` + `.sts2re/manifest.json`（sha1），路径白名单与 Android `WebDavSavePathMapper` 相同，填同一个槽位即可与 Android 共用。本地 baseline 做三方比较，两边都改过同一文件时提示冲突，由用户选择以云端或本机为准；拉取前自动快照。可开「自动同步」：打开启动器时上传上次进度、开始游戏前拉取。密码存钥匙串。
- Steam 云存档需要 Steam 账号协议，iPad 暂不支持（见下文 Steam 账号）。

不启用 `UIFileSharingEnabled`，避免把体积很大的正版 PCK 与整个 Documents 暴露给文件分享。仅通过文件选择器和分享面板按需传递 ZIP；设置页另有「文件浏览 / 文本编辑」（浏览 Documents，文本文件可编辑，保存前自动备份为隐藏文件、JSON 校验；StS2.pck 不可删）。

## 联机

联机设置位于 `Documents/Launcher/config.json`（schema 1），`network` 含 nickname、host、port（默认 33771）与 `playerId`。启动器与游戏补丁读同一份文件；每次保存都重新读取磁盘最新内容再合并，保留未知字段（含 MOD 管理写入的 resourceMods）。启动器自己的设置在根层 `launcher` 对象里。

「联机小屋」页：昵称与本机联机身份 ID、创建在线房间（开房时输入 frp 令牌）、在线房间列表（显示平台与版本，版本不同禁用加入）、局域网直连（局域网开房 / 填房主 IP 直连加入，显示本机局域网地址）。启动器通过 `pending-action.json` 让游戏到主菜单后自动开房或加入。协议细节、身份与续局规则见 [LAN_IOS.md](LAN_IOS.md)。

## MOD、创意工坊与 Nexus

资源 MOD 页默认接入 `STS2ModsViewController`，提供本地 ZIP/PCK 文件导入；也可通过 `LauncherViewController.modContentProvider` 覆盖。iOS 只能启用资源 PCK（和应用内置预编译能力匹配的编译 MOD），普通 DLL / Harmony MOD 归档并说明原因（NativeAOT 不能运行期加载程序集）。

- **创意工坊**（`STS2SteamWorkshop`、`STS2WorkshopViewController`；2026-11-09 按用户新要求恢复）：浏览/搜索/排序走 steamcommunity.com 工坊浏览页 + 公开的 `GetPublishedFileDetails`；「按链接 / ID 打开」只需 api.steampowered.com。详情页有截图（可全屏缩放、左右滑动）、简介、前置条目。下载走与 Android 相同的「尖塔补给站」公开协议（不接触 Steam 账号），从 Steam CDN 取 manifest 与分块：protobuf 解析、AES 解密、VZip 用系统 liblzma（运行时 dlopen，导出脚本无需加链接参数）、Steam Adler32 + SHA-1 校验。Zstd 分块（`VSZa`）暂不支持并明确提示。下载完成后经 `STS2ModStore` 导入本地 MOD；下载中禁止启动游戏。
  - 中国大陆网络下 steamcommunity.com 通常不可达，列表加载会给出说明；「按链接 / ID 打开」与下载仍可用。Android 用 `steamcommunity.rmbgame.net` 反代并跳过证书主机名校验，iPad 版出于安全**未采用**。
- **Nexus Mods**（设置 → 工具）：API key 存钥匙串；热门（v3，无需 key）/最新/最近更新；文件列表；Premium 直接下载，普通账号在网页点「Mod Manager Download」后粘贴 `nxm://` 链接；只导入 ZIP/PCK。

## 日志与诊断（规范 §5）

- 启动器日志 `Documents/Launcher/logs/launcher.log`，2 MiB × 5 滚动；行格式 `时间 级别 [标签] 消息 | 异常类型: 消息` + 缩进堆栈，标签固定集合（app/launch/online/frp/mods/saves/cloud/workshop/nexus/update/ui）。写入前脱敏：钥匙串里的令牌/密码/API key 原文、token/password/apiKey 等键值、Bearer。所有错误提示都先写 E 日志。
- 未捕获 ObjC 异常与致命信号（SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE/SIGTRAP，链式交给 .NET/Go 原处理器）写入 `pending-crash.txt`，下次启动补记到 launcher.log。
- 启动标记 `Documents/Launcher/launch-marker.json`：启动游戏前写（时间、版本、启动配置、资源 MOD），游戏补丁进入主菜单时删除；加载途中进入后台标记为 background。下次打开启动器发现 running 残留 → 写 W 日志并弹「上次游戏异常退出」，可直接查看或导出日志。
- 游戏内联机日志 `Documents/Launcher/online-game.log`（`[OnlineRoom]`，2 MiB 转存 `.1.log`）；游戏日志 `Documents/logs/*.log`；frp 日志 `Library/Caches/frpc.log`。
- 「日志」页：按类别列出上述日志，查看、搜索、按级别过滤（全部/信息+/警告+/仅错误），单个文件可分享（脱敏副本）；「导出日志」打包 `sts2-logs-ios-<yyyyMMdd-HHmmss>.zip`（各日志末尾 8 MiB、`diagnostics.json`、`config.redacted.json`、launch-marker）走分享面板。`diagnostics.json` 字段名与 Android `LogExportBundle` 相同（platform、generatedAt、osVersion、deviceModel、abis、launcherVersion、lastStartupMarker、launchProfile、mods、online、settings）。
- 「LLM 日志分析」对齐 Android `loganalysis/` + `llm/`：自定义 OpenAI 兼容 Chat Completions，只读工具 read_lines / search_logs，只发送模型按需读取的片段，24 轮预算，首次发送前征得同意；API key 存钥匙串。
- 日志等级（调试/信息/警告/错误）在日志页修改，保存在 `config.json` 的 `launcher.logLevel`。

## 设置

启动配置与版本信息（游戏版本、启动器版本、引擎、素材来源；iPad 只有一套游戏本体，不支持多配置与额外启动参数）、启动器更新检查（GitHub Releases，打开启动器时可自动检查，只提示并打开发布页，不自动安装）、文件浏览、云存档、Nexus Mods、Steam 账号、日志等级、关于。语言、画质等游戏设置在游戏内调整；iPad 只有 Metal 渲染器。

**Steam 账号**：iPad 版暂不支持登录。Steam 登录需要完整的 Steam 客户端协议（CM 连接、Steam Guard、refresh token 保管），Android 依赖的 JavaSteam 没有 iOS 版本；为安全起见不提供任何输入 Steam 密码的界面。工坊与云存档已有免登录路径。

## 功能对齐（规范 §6 iPad 列，2026-11-09）

| 功能 | 状态 |
| --- | --- |
| 主题/主页/导航 | 已有 |
| 本地 MOD | 已有（只能启用资源 PCK，DLL 归档） |
| 存档、快照、启动前快照、导入导出 | 已完成 |
| 启动配置与版本信息 | 已完成（单配置；额外参数不适用） |
| 联机小屋（在线房间、局域网直连、昵称、令牌、平台字段） | 已完成 |
| 日志查看、崩溃提示、导出、AI 分析 | 已完成（崩溃页为弹窗提示，非独立页面） |
| 创意工坊浏览/详情/图片/下载 | 已完成（Zstd 分块不支持；社区页需可访问 steamcommunity.com） |
| Steam 账号登录 | 未做（见上） |
| 云存档 WebDAV / Steam 云 | WebDAV 已完成；Steam 云未做（依赖 Steam 登录） |
| Nexus Mods 商店 | 已完成 |
| 启动器更新检查 | 已完成（只提示） |
| 文件浏览/文本编辑 | 已完成 |
| 设置项 | 已补齐 iPad 适用项（渲染器、键盘等平台不适用） |

## 离线测试

在 `sts2-ios` 根目录：

```sh
bash ios-export/launcher/tests/run-core-tests.sh      # 房间卡、pending-action、日志格式/脱敏/滚动、导出包、身份、AI 工具、Nexus、更新
bash ios-export/launcher/tests/run-webdav-tests.sh    # 本地临时 WebDAV 服务器，两台设备互推互拉、冲突、强制拉取
bash ios-export/launcher/tests/run-workshop-tests.sh  # 工坊解析、manifest、解密、VZip/ZIP 分块
```

原有存档与 MOD 数据层测试见 `launcher/README.md`、[MODS_IOS.md](MODS_IOS.md)。

## 应用到导出工程

在工作区根目录执行：

```sh
python3 ipad-tools/apply-scene-bridge.py
```

脚本复制启动器源码，dummy.cpp 仅包含 Scene bridge；launcher 各 `.mm` 独立加入 Xcode Sources，避免文件私有 static 名称冲突。添加 zlib 和 UniformTypeIdentifiers 链接参数、Scene manifest、本地网络说明，保留现有 Team 与签名配置。脚本可重复执行。

工作区的 `ipad-tools/stage-signed-app.py` 在签名前将用户原始 body ZIP 的 `release_info.json` 原样放在应用可执行文件旁，并先核对 ZIP 中游戏程序集与 `game-refs/sts2.dll` 的 SHA-256 一致。原版 `ReleaseInfoManager` 从这里读取版本；缺失时联机版本会变成 UNKNOWN，不能用跳过版本握手来替代正确打包。

启动器新增的 `.mm`（日志、云存档、工坊、Nexus 等）会被脚本自动加入 Sources；工坊 LZMA 在运行时 dlopen 系统 liblzma，不需要额外链接参数。验证应先做源代码语法检查和本地合成测试，再执行 Xcode 构建。设备安装只能覆盖安装，禁止 uninstall。UIKit 真机布局、首屏耗时、引擎仅启动一次和后台恢复仍需使用拥有正版素材的目标 iPad 验证。

## 主题：喵喵零和小鱼的小屋

启动器界面统一使用 `launcher/STS2Theme.{h,mm}`：奶油色小屋配色（深色模式为夜间小屋）、圆体字、圆角卡片和按钮样式。喵喵零（呆呆的八字分脸小猫）与小鱼（圆滚滚的小鲨鱼）是 `STS2MascotView` 用代码绘制的原创矢量图，不依赖任何外部图片，也不使用第三方角色素材。需要改配色或形象，只改这一个文件。
