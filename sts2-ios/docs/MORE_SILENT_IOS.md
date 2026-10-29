# More Silent Animations 0.1.33 固定静态移植

状态：2026-10-27 用户取消 Steam MOD 功能，固定静态移植工作已停止，未集成或启用。以下仅为研究记录；完整审计合同见 [MORE_SILENT_0133_PLAN.md](MORE_SILENT_0133_PLAN.md)。

Steam Workshop 项目 `3821353824` 当前主 DLL 是 MoreSilentAnimations 0.1.33，SHA-256 为 `1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41`。工具只使用 Mono.Cecil 读取和改写固定 DLL 与游戏 v0.111.0 的元数据，不加载或执行下载的 MOD。

输入检查固定原始游戏 SHA-256 `0861bfa1df347538d932f22d580e75420f08082792eb914e53b4882764acdbe9`、MOD SHA-256、原始/ woven 游戏 MVID 及至少 49 个基础 iOS hook。新版审计包含 66 个声明目标：43 prefix、35 postfix、13 finalizer、2 transpiler。目标重载、getter、hook 参数、顺序及私有字段均须按固定版本合同逐项匹配；未知合同或残留动态代码会拒绝输出。

适配 wrapper 在进入 hook 前读取冷启动 gate。gate 关闭时直接执行原实现；bool prefix 可跳过原实现；void 和 Exception finalizer 都会运行。异常时所有 finalizer 继续执行，清理异常不覆盖原异常。Task 返回方法保持 Task 结果和异常语义。两个 Harmony transpiler 由 Cecil 按固定 8 个调用点替换；内部 helper 也检查 gate，关闭时调用原始 Godot 方法。

gate 程序集必须提供 `IsMoreSilentEnabled`、`HasMoreSilentSupport`、`InitializeMoreSilent` 和对应固定常量。工具通过独立的 `--gate-output` 写出支持版本：把 `HasMoreSilentSupport` 改为 true，并让 `InitializeMoreSilent` 直接调用适配 MOD 入口。其余 gate 逻辑保持原样，输入程序集不会覆盖。

新版剩余私有访问桥和 `ComboHotkeyConflictPatch.__originalMethod` 专用静态转换仍未完成。当前工具对真实 0.1.33 输入 fail closed，不会生成 enabled gate，也不会用缺失 hook 冒充完整适配。

`ComboDiscardSelection.get_Selected()`、`Cancel()` 和异步 `Select` 状态机中的 3 个反射读取现已按 v0.111 固定字段桥接：`NPlayerHand._selectedCards` 是 `List<CardModel>`，`_selectionCompletionSource` 是 `TaskCompletionSource<IEnumerable<CardModel>>`。真实元数据转换现继续到下一个合同缺口 `ComboHotkey.get_Titles()`，仍然 fail closed。此前固定目标解析、43/35/13 hook 数量、8 个 transpiler 调用点和 helper gate 检查通过；这不替代最终输出重读审计。

构建使用本仓库已有 dotnet 工具链，并仅从缓存还原依赖：

```sh
dotnet build sts2-ios/tools/MoreSilentStaticPort -c Release --no-restore
dotnet sts2-ios/tools/MoreSilentStaticPort/bin/Release/net9.0/MoreSilentStaticPort.dll \
  --base-game sts2-ios/game-refs/sts2.dll \
  --game sts2-ios/ios-export/.work/sts2-v0.111.0-woven.dll \
  --mod /path/to/verified/MoreSilentAnimations.dll \
  --gate sts2-ios/ios-export/.work/runtime-gate-out/STS2MobileIos.dll \
  --manifest sts2-ios/src/STS2MobileIos/manifest.json \
  --output sts2-ios/ios-export/.work/more-silent-static \
  --gate-output sts2-ios/ios-export/.work/more-silent-gate
```

完整成功后会输出适配的 `sts2.dll`、`MoreSilentAnimations.dll`、独立 gate DLL 和转换报告。产物还须加入 NativeAOT 引用/根与能力清单，完成 AOT 编译及设备验收，才能宣称运行时启用。

独立合成测试只执行工具自带的 game/hook fixture，不执行下载 DLL：

```sh
dotnet sts2-ios/tools/MoreSilentStaticPort/bin/Release/net9.0/MoreSilentStaticPort.dll --self-test
```

离线静态转换不能证明设备上的 Spine/GDScript、动画显示、帧率或联机行为正确。启用和禁用冷启动、猎人卡牌动作以及 LAN/跨端 MOD 行为都需要实际验收。
