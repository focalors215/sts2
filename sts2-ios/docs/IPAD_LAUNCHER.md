# iPad 原生启动器

冷启动先创建 UIKit 中文启动器；点“开始游戏”才进入 Godot。iPad 常规宽度使用游戏、存档、MOD、联机侧栏；紧凑宽度使用顶部标签。文字随系统字号调整，使用系统颜色、SF Symbols 和至少 48 点操作按钮。

开始游戏前按应用真实 `godot_cmdline` 检查素材。当前完整包使用应用内置的 `StS2.pck`；不能仅因 Documents 没有同名文件就拒绝启动。明确配置 `--main-pack user://StS2.pck` 的瘦身包则检查 Documents 对应文件。素材必须是非空普通文件。

## 启动与生命周期

`ios-export/StS2SceneDelegate.mm` 在 Objective-C `+load` 中只替换 Godot 4.5.1 的 `GDTAppDelegateService` 启动方法：保存 service 与 launchOptions，返回 YES。Scene 自己创建启动器窗口。

开始操作检查前台状态，以 Launcher → Starting → Running / Failed 状态机防止重复启动。在主队列调用保存的原始启动 IMP，原引擎初始化、静态 mainViewController 及音频会话设置均保留。service 的 setWindow: 钩子在原代码展示窗口前绑定 UIWindowScene。成功后复用原 Godot 窗口和控制器。

前台、激活、失活、后台事件只在 Running 时转发；引擎启动前的 AppDelegate 生命周期、内存警告和退出通知由 guard 屏蔽。Scene 断开时保留游戏窗口，重新连接时复用。同一进程只允许调用引擎入口一次；失败需完全关闭应用后重开，不能卸载再初始化 Godot。原 Godot 入口内部的致命退出不能被 Objective-C 异常处理捕获。

## 存档

启动器读取 `Documents/default/1`，通过单独串行队列运行存档枚举、ZIP 导入、导出和备份。导入使用系统文件选择器；导出使用系统分享面板。导入或恢复前显示确认，数据层在替换前自动创建已有存档快照。游戏开始后不允许管理存档。

不启用 `UIFileSharingEnabled`，避免把体积很大的正版 PCK 与整个 Documents 暴露给文件分享。仅通过文件选择器和分享面板按需传递 ZIP。

## 联机与 MOD

联机设置位于 `Documents/Launcher/config.json`，schemaVersion 为 1，network 包含 nickname、host、port（默认 33771）。每次保存重新读取磁盘上的最新配置，再只更新网络字段，保留未知顶层和 network 字段，包括之后由 MOD 管理写入的 resourceMods。此页配置直连参数，适用于 LAN 或有公网 UDP 端口映射的主机，不宣称 Steam P2P 可用。同页“远程联机”使用内置 frp 客户端为房主建立 UDP 穿透，见 [LAN_IOS.md](LAN_IOS.md#远程联机frp-穿透)。

资源 MOD 页默认接入 `STS2ModsViewController`，提供本地 ZIP/PCK 文件导入；也可通过 `LauncherViewController.modContentProvider` 覆盖。控制器使用独立内容容器，切换标签保留其状态。2026-10-27 用户取消 Steam 工坊需求，当前启动器已移除工坊入口和下载调用，导出脚本也不再把 Workshop 客户端及其 LZMA 解码器编译进应用。

## 应用到导出工程

在工作区根目录执行：

```sh
python3 ipad-tools/apply-scene-bridge.py
```

脚本复制启动器源码，dummy.cpp 仅包含 Scene bridge；launcher 各 `.mm` 独立加入 Xcode Sources，避免文件私有 static 名称冲突。添加 zlib 和 UniformTypeIdentifiers 链接参数、Scene manifest、本地网络说明，保留现有 Team 与签名配置。脚本可重复执行。

工作区的 `ipad-tools/stage-signed-app.py` 在签名前将用户原始 body ZIP 的 `release_info.json` 原样放在应用可执行文件旁，并先核对 ZIP 中游戏程序集与 `game-refs/sts2.dll` 的 SHA-256 一致。原版 `ReleaseInfoManager` 从这里读取版本；缺失时联机版本会变成 UNKNOWN，不能用跳过版本握手来替代正确打包。

验证应先做源代码语法检查和本地合成存档测试，再执行 Xcode 构建。设备安装只能覆盖安装，禁止 uninstall。UIKit 真机布局、首屏耗时、引擎仅启动一次和后台恢复仍需使用拥有正版素材的目标 iPad 验证。

## 主题：喵喵零和小鱼的小屋

启动器界面统一使用 `launcher/STS2Theme.{h,mm}`：奶油色小屋配色（深色模式为夜间小屋）、圆体字、圆角卡片和按钮样式。喵喵零（呆呆的八字分脸小猫）与小鱼（圆滚滚的小鲨鱼）是 `STS2MascotView` 用代码绘制的原创矢量图，不依赖任何外部图片，也不使用第三方角色素材。需要改配色或形象，只改这一个文件。
