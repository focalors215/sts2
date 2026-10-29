# More Silent Animations 0.1.33 固定静态移植计划

2026-10-27：用户已取消 Steam MOD 功能，静态移植工作停止，未生成可启用的 MOD 或签名应用能力。本文仅作为后续研究记录。

状态：**仅完成只读兼容性评估，尚未移植、AOT 编译或启用**。本次不改变 `Adapter.cs` 的 hash 门禁、生产代码或已装机包；当前 `CompiledModPatches.IsMoreSilentEnabled()` 仍恒为 `false`。本计划不应被启动器用作“已支持”凭据。

评估日期：2026-10-27。仅用 Mono.Cecil 读取 Workshop 下载 DLL 的元数据/IL，没有执行下载的 DLL。私有检查器及完整证据位于 `ios-export/.work/mod-0133-audit/`，不作为可分发 MOD 文件提交。

## 输入与结论

Workshop 项目 `3821353824` 当前 manifest 为 `0.1.33`，主 DLL SHA256 为 `1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41`（这是 SHA256，不是 SHA1）。声明依赖 .NET 9、GodotSharp 4.5.1、0Harmony 2.4.2；直接引用的 191 个游戏成员按现有适配器签名规则均能在原游戏 v0.111.0 中找到。此结果不包含反射查找的成员，也不证明运行时兼容。

旧 0.1.16 的 32 个 patch 类都仍存在，旧 attributed hook 的签名没有移除或改变。但新版本共有 **66 组：43 prefix、35 postfix、13 finalizer、2 transpiler**，新增 34 组。必须重新审计和转换，不能只修改 hash 和计数。

## 具体 target 清单

下表保留 DLL 中的类名及目标类型全名；省略目标类型的共同前缀 `MegaCrit.Sts2.Core.`。`动态` 行必须通过下节的固定映射展开，禁止装机后运行反射目标发现。第三参数为 `Type[]` 的既有目标必须保留原重载约束，不能按同名第一个方法绑定。

| Patch 类（MoreSilentAnimations.） | 固定声明目标 |
| --- | --- |
| `ComboMusicVolumePatch` | `Nodes.Audio.NAudioManager::SetBgmVol` |
| `ComboAmbienceVolumePatch` | `Nodes.Audio.NAudioManager::SetAmbienceVol` |
| `ComboDiscardScopePatch` | `Commands.CardSelectCmd::FromHandForDiscard` |
| `ComboDiscardSubmitPatch` | `Nodes.Combat.NPlayerHand::SelectCards` |
| `ComboDiscardSelectionFeedback` | `动态；见下方固定展开` |
| `ComboDiscardSelectionTiming` | `动态；见下方固定展开` |
| `ComboExitPatch` | `动态；见下方固定展开` |
| `ComboHandTiming` | `动态；见下方固定展开` |
| `ComboHotkeyDefaultsPatch` | `动态；见下方固定展开` |
| `ComboHotkeyModalPatch` | `ControllerInput.MegaInput::AllInputs（属性 getter）` |
| `ComboHotkeyConflictPatch` | `动态；见下方固定展开` |
| `ComboHotkeyCapturePatch` | `Nodes.Screens.Settings.NInputSettingsPanel::_UnhandledKeyInput` |
| `ComboHotkeyEntryPatch` | `Nodes.Screens.Settings.NInputSettingsEntry::_Ready` |
| `ComboModOnlyInputRowPatch` | `Nodes.Screens.Settings.NInputSettingsPanel::_Ready` |
| `ComboPreviewHoverIdentityPatch` | `Multiplayer.Game.PeerInput.PeerInputSynchronizer::SyncLocalHoveredModel` |
| `ComboNativeShivPlayPatch` | `Nodes.Combat.NCardPlay::TryPlayCard` |
| `ComboPreviewNeverEnqueuePatch` | `Models.CardModel::TryManualPlay` |
| `ComboLocalHandSelectionPatch` | `Nodes.Combat.NPlayerHand::SelectCards` |
| `ComboLocalHandOrderPatch` | `Nodes.Combat.NPlayerHand::RefreshLayout` |
| `ComboPreviewRememberSlotPatch` | `Nodes.Combat.NPlayerHand::StartCardPlay` |
| `ComboPreviewReturnSlotPatch` | `Nodes.Combat.NPlayerHand::GetHandInsertIndex` |
| `ComboPlanningAttachPatch` | `Nodes.Combat.NCombatUi::Activate` |
| `ComboPlanningDeactivatePatch` | `Nodes.Combat.NCombatUi::Deactivate` |
| `ComboPlanningGatePatch` | `GameActions.ActionExecutor::WaitForUnpause` |
| `ComboPlanningHitStopPatch` | `Nodes.Vfx.Utilities.NHitStop::SetTimeScale` |
| `ComboPlanningButtonFeedbackPatch` | `动态；见下方固定展开` |
| `ComboPlanningQueueFeedbackPatch` | `Nodes.Combat.NCardPlayQueue::TweenCardToQueuePosition` |
| `ComboShivRequestPatch` | `GameActions.Multiplayer.ActionQueueSynchronizer::RequestEnqueue` |
| `ComboShivQueueDisplayPatch` | `Nodes.Combat.NCardPlayQueue::OnActionEnqueued` |
| `ComboShivQueueIndexPatch` | `Nodes.Combat.NCardPlayQueue::TweenCardToQueuePosition` |
| `ComboShivChoicePatch` | `GameActions.Multiplayer.ActionQueueSet::PauseActionForPlayerChoice` |
| `ComboShivCreatedPatch` | `动态；见下方固定展开` |
| `CreatureCenterEffectPatch` | `Commands.VfxCmd::PlayOnCreatureCenter` |
| `HitSparkPositionPatch` | `Nodes.Vfx.NHitSparkVfx::_Ready` |
| `BlockSparkPositionPatch` | `Nodes.Vfx.NBlockSparkVfx::_Ready` |
| `DamageNumberContextPatch` | `Nodes.Vfx.NDamageNumVfx::Create（显式 Type[] 重载）` |
| `DamageNumberPositionPatch` | `Nodes.Vfx.NDamageNumVfx::Create（显式 Type[] 重载）` |
| `NativeEffectPositionPatch` | `Commands.VfxCmd::PlayVfx` |
| `WhiteSlashPatch` | `Nodes.Vfx.Utilities.NSpriteAnimator::_Ready` |
| `EchoingSlashPresentationPatch` | `Models.Cards.EchoingSlash::OnPlay` |
| `EchoingSlashRoundPatch` | `动态；见下方固定展开` |
| `FinalePresentationPatch` | `Models.Cards.GrandFinale::OnPlay` |
| `FinaleFactoryPatch` | `Nodes.Vfx.NGrandFinaleVfx::Create（显式 Type[] 重载）` |
| `AttackPresentationPatch` | `Commands.Builders.AttackCommand::Execute` |
| `NativeActionPatch` | `Nodes.Combat.NCreature::SetAnimationTrigger` |
| `NativeDeathPresentationPatch` | `Nodes.Combat.NCreature::StartDeathAnim` |
| `RunCleanupPatch` | `Runs.RunManager::CleanUp` |
| `CreaturePreloadPatch` | `Nodes.Combat.NCreature::_Ready` |
| `KnifeTrapPresentationPatch` | `Models.Cards.KnifeTrap::OnPlay` |
| `KnifeTrapHitTargetPatch` | `Commands.Builders.AttackCommand::WithHitVfxNode` |
| `KnifeTrapFactoryTargetPatch` | `Nodes.Vfx.NShivThrowVfx::Create（显式 Type[] 重载）` |
| `PoisonPresentationPatch` | `动态；见下方固定展开` |
| `PoisonCastCompletionPatch` | `Commands.CreatureCmd::TriggerAnim` |
| `PoisonImpactStartupPatch` | `动态；见下方固定展开` |
| `NativeBottleCapturePatch` | `Nodes.Vfx.NItemThrowVfx::Create` |
| `NativeBottleTrailPatch` | `Nodes.Vfx.NItemThrowVfx::_Ready` |
| `ReturnKnifePatch` | `Commands.Builders.AttackCommand::Execute` |
| `ReturnRevealPatch` | `Combat.History.CombatHistory::CardPlayStarted` |
| `SettingsLocalization` | `Localization.LocManager::Initialize` |
| `ShivPresentationPatch` | `Commands.Builders.AttackCommand::Execute` |
| `ShivFactoryPatch` | `Nodes.Vfx.NShivThrowVfx::Create（显式 Type[] 重载）` |
| `ShivVisualReadyPatch` | `Nodes.Vfx.NShivThrowVfx::_Ready` |
| `SnakebitePresentationPatch` | `Models.Cards.Snakebite::OnPlay` |
| `SnakebiteActionPatch` | `Nodes.Combat.NCreature::SetAnimationTrigger` |
| `SteelPresentationPatch` | `Models.Cards.StormOfSteel::OnPlay` |
| `TrackingPresentationPatch` | `Models.Cards.Tracking::OnPlay` |

动态目标的固定展开：

- `ComboDiscardSelectionFeedback` → `NPlayerHand.SelectCardInSimpleMode`、`DeselectCard`。
- `ComboDiscardSelectionTiming` → 下方 5 个 CreateTween 调用点。
- `ComboExitPatch` → `NGame.ReturnToMainMenu`、`GoToTimeline`。
- `ComboHandTiming` → 下方 3 个异步状态机调用点。
- `ComboHotkeyDefaultsPatch` → v0.111.0 的 `NInputManager.get_DefaultHotkeyInputMap`、`get_DefaultKbOnlyInputMap`。DLL 兼容探测列表中的 `get_DefaultKeyboardInputMap` 在此游戏版本不存在，不能强行要求存在或静默改绑。
- `ComboHotkeyConflictPatch` → v0.111.0 的 `NInputManager.ModifyMKbKey`、`ModifyKbOnlyKey`；兼容探测名 `ModifyShortcutKey` 在此版本不存在。
- `ComboPlanningButtonFeedbackPatch` → `NPauseMenuButton.OnFocus`、`OnUnfocus`、`OnPress`，同时重写读取该按钮私有字段的逻辑。
- `ComboShivCreatedPatch` → `Shiv.CreateInHand(Player, int, ICombatState, Player)`，返回 `Task<IEnumerable<CardModel>>`。另一个 `CreateInHand(Player, ICombatState, Player)` 返回 `Task<CardModel>`，不能误绑。
- `EchoingSlashRoundPatch` → `CreatureCmd.Damage(PlayerChoiceContext, IEnumerable<Creature>, DamageVar, Creature, CardModel, CardPlay)`，参数名依次为 `choiceContext, targets, damageVar, dealer, cardSource, cardPlay`。
- `PoisonPresentationPatch` → `BubbleBubble.OnPlay`、`DeadlyPoison.OnPlay`、`BouncingFlask.OnPlay`。
- `PoisonImpactStartupPatch` → `NGaseousImpactVfx._Ready`、`NPoisonImpactVfx._Ready`。

在真正更新适配器前，还需把下表声明目标及上述展开产出为机器可读审计清单，固定完整签名、同目标组顺序、参数绑定、字段类型和方法体匹配数。原始及 woven 游戏都要检查，最终输出逐项保留原有至少 49 个基础 iOS hook。

## Adapter 和 Wrapper 的最小增量

1. 保留旧版本拒绝规则，为 0.1.33 增加独立、完整的已审计输入记录；目标发现只消费元数据，不执行 `TargetMethods`、`TargetMethod` 或 Harmony。未知组、未知目标、重载歧义、未知 Harmony 排序语义一律拒绝输出。
2. `ComboModOnlyInputRowPatch.Finalizer` 返回 **void**，旧 Wrapper 仅接受 Exception；新增 void finalizer 语义并继续保证清理器抛异常时不丢原异常、其余清理器仍执行。
3. `ComboPlanningQueueFeedbackPatch`、`ComboShivQueueIndexPatch` 的 `item` 参数为 object。检查实际游戏私有参数类型后，仅允许可证明安全的引用类型拓宽；ref 参数继续要求精确类型，不能笼统关闭检查。
4. `ComboHotkeyConflictPatch` 需要 `__originalMethod`。优先将此固定 MOD 的 BeforeKeyChange 适配为构建时确定的 enum/分支，分别生成两个目标的专用 hook，避免引入运行时 MethodBase/Invoke。
5. `ComboHotkeyModalPatch` 的第三个 Harmony 参数是 MethodType.Getter，不是 Type[]。明确解析 `MegaInput.get_AllInputs()`，拒绝其他未经实现的 MethodType。
6. `Task<T>` 结果 ref/postfix 和两组同目标 SelectCards / 队列 hook 应按固定元数据顺序组合，状态按调用和组隔离；合成测试覆盖跳过原方法、重入、异步成功/失败及清理。已有 12 项合成测试必须保持通过。

## 两个 transpiler 的确定性替换

不执行 Harmony Transpiler，直接由 Cecil 对固定游戏方法体做下列调用替换。只改已有指令的 opcode/operand，保留其分支目标和异常区域；静态 helper 参数补齐原实例接收者，保持求值栈形状。每个位置在原始 v0.111.0 中都已读到 **恰好 1 次** 匹配。

| 游戏方法体 | 原调用 | 固定替换 |
| --- | --- | --- |
| `NPlayerHand/<SelectCards>d__83.MoveNext` | `Node.CreateTween()` | `ComboDiscardSelectionTiming.CreateTween(Node)` |
| `NPlayerHand.AfterCardsSelected(AbstractModel)` | 同上 | 同上 |
| `NPlayerHand.UpdateSelectedCardContainer(int)` | 同上 | 同上 |
| `NSelectedHandCardHolder._Ready()` | 同上 | 同上 |
| `NHandCardHolder.SetCard(NCard)` | 同上 | 同上 |
| `NHandCardHolder/<AnimPosition>d__50.MoveNext` | `Node.GetProcessDeltaTime()` | `ComboHandTiming.HandDelta(Node)` |
| `NHandCardHolder/<AnimAngle>d__48.MoveNext` | 同上 | 同上 |
| `NHandCardHolder/<AnimScale>d__49.MoveNext` | 同上 | 同上 |

选择 tween helper 只在 `ComboDiscardSelection.Owns(node)` 时 SetIgnoreTimeScale(true)。HandDelta 只在本地 planning 激活、非网络且是当前玩家手牌时除以 TimeScale。新增 gate-aware bridge：gate 关闭时必须直接走原始 Godot 调用，不能仅依赖游戏 public wrapper gate，因为这 8 处位于内部方法体/状态机中。

转换必须验证完整 Godot 方法签名与预期指令数。DLL 原 transpiler 对前一类只要求非零，固定版本工具应采用本次已验证的每处 1 次、更严格条件。Base woven 游戏若偏离则停下报告，不用宽松搜索“修复”。移除不再使用的 transpiler/iterator 与 Harmony.CodeInstruction 签名，确保 AOT 不再需要 0Harmony。

## 私有绑定与动态代码清理

旧四字段、五次读取 + GetPossibleTargets 不足以覆盖新版。新增至少包括：

- `NPlayerHand._selectionCompletionSource`、`_selectedCards`、`_currentCardPlay`。
- `NCardPlay._isTryingToPlayCard`、`Cleanup`，包括字段写入。
- `NInputSettingsEntry` 标题字典；`NInputManager` remappable 列表、`_mKbInputMap`、`_fKbInputMap` 及相应保存/获取方法；`NInputSettingsPanel._listeningEntry`、`_listeningPrompt`；控制器停止监听和设置条目更新。
- `NPauseMenuButton` 反馈使用的私有字段。
- `ShivPresentationPatch` 的 `CardPlay.Player` PropertyInfo→CreateDelegate：改为直接强类型 getter/delegate，不能指望反射元数据刚好保留。

为每个实际使用的 v0.111.0 成员建立精确合同。DLL 还探测旧版本名字（如 `_keyboardInputMap`、GetShortcutKey、KeyboardOnlyMode）；固定移植只保留当前版本已验证分支，删除无用反射分支。桥应在所属游戏类型内产生，调用点明确指向对应桥，避免根据“最近见到的字段”推断。

`ModEntry.Initialize` 新增 `ComboHotkey.Install`，旧 rewrite 只调用本地化和设置会漏功能。完成 typed rewrite 后再保留安装。`OptionalModSettings` 仍使用默认和本地设置加载，不动态加载可选 Settings/BaseLib。新的 `ComboSpeedCompatibility` 与已有 `SilentFxCompatibility` 都探测未打包外部 MOD 并动态 Harmony.Patch；本构建需显式惰性空实现，并在报告列出省略的第三方兼容功能。

最终残留审计应涵盖可执行 IL、嵌套 helper、字段及方法签名、自定义属性：0Harmony/HarmonyLib、AssemblyLoadContext、动态 Assembly.Load、FieldInfo.GetValue/SetValue、PropertyInfo.GetValue、MethodBase.Invoke、未知 MethodInfo.CreateDelegate 等。允许已审计的自身 EmbeddedResource 读取和普通 typeof/类型名使用，不能把一切反射一概删除，也不能仅靠旧 scanner 通过便宣称 AOT 安全。

## 资源与骨架

48 个嵌入资源（旧 43 个）。新增 `skin_pose.gd`、beta/stable `finale-slash.native.br`、`finale-smoke.gdshader`、`skin-smoke.gdshader`；`native_pose.gd` 长度 57832→60626，`skin_guard.gd` 2953→3677。每个输出资源都要与新输入逐字节/SHA256 对比。相同长度不等于内容未变。

新 rig-identity 仍声明 beta 骨架 SHA256 `451d45513401f7ecd68160c82387bc318fe58282aa46173d9b04e4bc38154322`，与此前当前游戏骨架检查值一致；stable 为 `17294850ae4e0b397b4dc2733af03d2b0d53d88fa504ad69a36d68bb2bbac6b0`。导入路径仍为 `res://.godot/imported/silent.skel-6b655a4fd5b64cebd28f191d15f9cfc4.spskel`，upper-cloth 边界仍为 slot26/top leg/offset58039/count81。这里只核对了新版身份声明，没有据此证明 Spine/GDScript/纹理运行正确。

## runtime gate 与原生 capabilities 接口（拟议，尚未实现）

原生 UI 与托管 gate 必须共享构建生成的能力记录，不能以下载清单中的 has_dll 或已安装状态开启代码功能：

- 在签名 App bundle 内生成只读 `compiled-mods.json`，记录 `schemaVersion`、`buildId`、`gameVersion`、`id`、`version`、原始 MOD SHA256、adapterRevision、支持/省略的特性及网络兼容标识。它只能由成功转换/AOT 构建生成；Documents 中的用户文件不能伪造支持能力。
- 原生 `STS2ModStore` 加载 bundle 能力列表，对安装记录进行精确 id/version/hash 匹配。只有匹配记录才提供“下次启动启用”开关；其他 DLL 保持“需要静态编译”。与现有根 `resourceMods` 分开保存 `compiledMods` 启动意图，写配置时继续与其他管理器合并并持同一锁。
- 托管 `CompiledModPatches` 在冷启动时一次读取配置并验证编译时常量/能力及被选择安装记录；初始化适配 DLL 一次且在首个 MOD hook 之前完成。成功后才使 `IsMoreSilentEnabled()` 返回 true；任何验证/初始化失败保持 false。构建需加入适配 DLL 的 Reference、TrimmerRootAssembly、实际调用根和所需 Godot 类型注册，不只是拷贝 DLL 到 deps。
- 8 个内部调用替换与所有 wrapper 读取同一冻结 gate。游戏运行期间不热切换；返回启动器应说明需要完整重开，保持存档/MOD 文件操作的现有互斥。
- 独立原子写 `Documents/Launcher/compiled-mod-load-status.json`，记录 buildId、id/version/hash、requested、initialized、enabled/failed 与 reason。原生 UI 对比当前 buildId 显示“已编译/待重启/本次已加载/失败”，不能用上次运行日志冒充本次状态。
- 正常联机仍默认关闭未经跨端验收的代码 MOD；若启用网络功能，必须明确传递已编译 MOD 的身份/特性到现有握手或设置兼容限制。manifest `affects_gameplay:false` 不足以证明新的 ActionQueue/PeerInput/选牌拦截不会改变同步行为。

## 最小任务拆分与验收

1. 固定清单/私有合同：逐个解析上述 66 组，生成完整签名、hook 绑定/顺序、每处 call-site 计数报告；原始与至少 49-hook woven 都通过。任何变化拒绝输出。
2. Adapter/Wrapper：实现明确支持增量、8 处 deterministic rewrite 和 typed bridge；保留旧门禁，增加 gate-aware 内部桥；嵌入资源 48/48 完整。真实转换仅做元数据处理和产物重读，不执行下载 DLL。
3. 合成测试：旧 12 项继续通过，新增 void finalizer、可证明的 object 拓宽、getter target、固定 original-method 分支、Task<T> result、8 处 gate 开/关、零/多匹配拒绝、所有清理路径；重读产物验证原游戏身份/MVID/基础 hook 和无残留动态代码。
4. runtime/native 接口：精确匹配 bundle capabilities、冷启动冻结 gate、初始化一次、真实加载状态、AOT root；不匹配和失败一律不启用。通过新构建日志处理真实 NativeAOT/Godot 元数据/JSON/资源和脚本错误，不能以静态分析替代构建。
5. 装机：启用和禁用分别冷启动验证。猎人打击、防御、毒、生成/排队飞刀、弃牌选择与取消、GrandFinale、EchoingSlash、planning/time scale、离开战斗/回菜单/后台返回、设置及读写存档均需实际测试。无卡住的选牌 Task/残留慢动作，牌效果结果不变；记录首次特效卡顿和帧时间，不能只看平均 FPS。
6. 网络：先完成 MOD 关闭时 Android v0.111.0 ↔ iPad LAN 的加入/选人/战斗/结束与断线测试。新版 MOD 启用后另测同版本对端和无 MOD 对端，验证同步/拒绝策略；互联网、Steam P2P 没有真实测试不得宣称完成。

本轮 root 优先 launcher/LAN 实测，本计划不应阻塞其构建。若只先移植旧 32 组动画及部分新效果，应在 UI/文档明确命名为“0.1.33 动画子集”，列出关闭的预规划/快捷键/队列功能；不能静默删掉新增组后标为完整 0.1.33。
