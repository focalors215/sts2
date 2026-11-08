# iPad 构建 v0.107.1 的可行性评估（2026-11-09）

结论：**可行，但不是改个版本号就能出包**。需要单独一套 v0.107.1 的 NativeAOT 构建（独立 App 或独立 bundle id），补丁按版本条件编译，预计 2–4 个工作日开发 + 真机验收；本轮没有实施。

## 为什么不能和 v0.111.0 共用一个 App

- iOS 不能运行时加载程序集，游戏代码是构建时织入后 NativeAOT 编译进 `sts2.framework` 的。一个 App 只能带一份编进去的游戏程序集；同一 App 内按版本切换需要同时内嵌两套 AOT 框架并改 Godot .NET 启动胶水，风险高、收益低。
- 两个版本的 `StS2.pck`（各约 1.8 GB）必须分别保存，Documents 空间翻倍。
- 联机要求版本、ModelDb hash 完全一致，v0.107.1 与 v0.111.0 本来就不能互联；单独的 App 不影响三端互通的设计（iPad↔Android↔Windows 在 v0.107.1 互联靠各自都有 v0.107.1 构建）。

建议：用同一套流水线产出第二个 App（例如 bundle id 加 `.v0107` 后缀），图标/名字标出版本；启动器代码完全复用，`release_info.json` 决定显示的版本，房间列表自然只显示同版本房间。

## 需要做的工作

1. **取得 v0.107.1 正版文件**：用户自己的 Steam 公开分支 `sts2.dll`、`release_info.json`、PCK 与 GDExtension 依赖。本机目前只有 v0.111.0 的 `game-refs`，`Sts2MobileLauncher/port-mod/refs/original-v0.107.1/` 只有占位 README，**没有** v0.107.1 DLL，所以本轮无法用 LanApiProbe 实测。
2. **确认引擎与原生库版本**：v0.107.1 使用的 Godot 版本、Spine / FMOD GDExtension 版本要与导出模板一致；若不是 Godot 4.5.1，需要对应的 mono 编辑器与 iOS 模板，`StS2SceneDelegate.mm` 依赖的 `GDTAppDelegateService` 启动方法也要重新核对。
3. **补丁按版本条件编译**（参照 Android `port-mod` 的 `STS2_TARGET_1110` 分支，已确认的差异）：
   - v0.107.1 的 `NetHostGameService` / `NetClientGameService` 构造函数**没有** `PeerVersionInfo` 参数，`JoinFlow` 为无参构造（Android：`#if STS2_TARGET_1110 … #else new NetHostGameService()`）。
   - `PeerVersionInfo.LocalDefault` 在 v0.107.1 不存在，`ResourcePackPatches.LocalDefaultPostfix`（资源 PCK 指纹并入握手）需要换成该版本的等价挂点（Android 在旧版本上挂 `InitialGameInfoMessage.Basic`）。
   - `LanApiProbe --verify` 的「game-owned join flow contracts」检查（`LocalDefault`/`.ctor`/`Begin`）需要按版本调整。
   - 其余 50 处钩子（布局、着色器预热、生命周期、快照、四倍速、选牌助手等）逐个用 LanApiProbe 对 v0.107.1 DLL 核对目标类型/方法/参数名，缺失的在 manifest 变体里去掉或改挂点。
4. **manifest 与构建脚本**：`manifest.json` 拆成按版本选择（或加 `targets` 字段由织入器过滤）；`build-ios.sh` / `rebuild-managed.sh` 增加版本参数，产物目录分开。
5. **续局身份与联机日志**：本轮实现的 §3.4 判定（先 playerId 后 1）和 `OnlineRoomLog` 不依赖 v0.111.0 专有 API，可直接复用。
6. **验收**：真机首帧/内存/着色器预热、存档读写、与 Android v0.107.1 同 Wi‑Fi 和 frp 联机、续局。

## 风险

- 旧版本若有 v0.111.0 补丁未覆盖的 iOS 崩溃点（着色器、生命周期），需要重新做一轮真机排查（参考 `docs/patch-catalog.md` 的三大难题）。
- 免费开发者账号的 App 数量与 7 天签名限制：两个 App 都要续签。
