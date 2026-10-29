# Local iPad mini 7 build

Target: iPad mini 7, iPadOS 27. This checkout has not yet been installed or tested on that device.

The user's v0.111.0 Android body archive supplies the private game assemblies and PCK. Build inputs remain in ignored `game-refs/`, `ios-export/.work/` and `ios-export/prebuilt/`. The original archive is unchanged. The Godot 4.5.1 mono release API supplies `GodotSharp.dll` for patch compilation.

Patch library compilation and all 37 static weaving entries passed against this input. This resolves the previously suspected target-method spelling mismatch for this particular DLL; it does not prove the hooks behave correctly during gameplay.

`ios-export/sts2.csproj` explicitly references Microsoft's `System.IO.Hashing` 9.0.0 package, as declared by the game's `sts2.deps.json`. The Android optimized archive omits this assembly and .NET's shared framework does not supply it. Without the package, NativeAOT emits `will always throw` diagnostics for game hashing/model-serialization methods. Package source: https://www.nuget.org/packages/System.IO.Hashing/9.0.0 (MIT; see package license and third-party notices).

The PCK contains 15,862 entries, iOS FMOD/Spine library declarations, and no native library files. Matching iOS binaries remain necessary. NativeAOT trim/dynamic-code warnings require analysis and device validation even if compilation succeeds.

This PCK already contains 3,542 `.cs` placeholder resources and an extension list containing only FMOD and Spine. Its `project.binary` has no Sentry keys. The older `pck_patch_sentry.py` requires a SentryInit entry and is inappropriate for this optimized input; the local exporter uses the staged game PCK unchanged.

`ios-export/sts2.sln` is required even though the publishing command targets `sts2.csproj`: Godot 4.5.1's C# ExportPlugin uses solution-file existence to decide whether to include the NativeAOT game framework. Without it, an otherwise successful project export omits the managed game. The local export helper verifies the generated project references `sts2_aot.xcframework`.

FMOD's official `6.1.0-4.5.0` `addons.zip` release includes the needed iOS framework and static libraries under `fmod/libs/iOS/` (capitalization matters). They are staged under the lowercase `addons/fmod/libs/ios/` path expected by this game's descriptor. Spine 4.2 was built locally with the Godot 4.5 C++ binding and Xcode 27.1, using `platform=ios arch=arm64 ios_simulator=no target=template_release`. Exact commits and download hashes are recorded in sibling `ipad-tools/toolchain-lock.json`.

Build tooling is installed only under sibling `ipad-tools/toolchain/`: .NET SDK 9.0.319 and official Godot 4.5.1 mono. Xcode 27.1 with iPhoneOS 27.1 SDK is available. Signing and device deployment are separate pending steps; no device was detected at the time of this check.

## iPadOS 27 UIScene 兼容进展

真机信任后首轮启动在 `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` 中 SIGTRAP。新增 `ios-export/StS2SceneDelegate.mm`，由工作区 `ipad-tools/apply-scene-bridge.py` 写入生成工程：dummy.cpp 按 Objective-C++ 编译并包含桥接；Info.plist 使用单 UIWindowScene 配置。保留原 Godot controller/窗口和初始化，scene 事件转发应用 delegate。Xcode Release 构建、严格签名通过，实机已越过原崩溃，日志出现 connected → foreground → active，截图显示中文首次运行提示和主菜单。战斗、声音、触摸、后台恢复和断网运行尚待验证。

## 性能诊断与候选修复

HUD 实测：旧全量场景预热期间 5.33 FPS、GPU 6.55 ms；跳过预热同分辨率 2266×1488 / 同4倍速菜单约60 FPS，战斗待机59.5 FPS / GPU12.08 ms。用户确认出牌特效主要第一次停顿，再次出现改善。Godot4.5的Canvas2D管线在首次绘制编译，不宜用长期低FPS问题解释首次特效尖峰。

正常启动不再自动扫描全部场景。候选可选准备流程：Documents/shader_warmup_on存在时启动材质预热，可取消并显示进度；只从明确的文本材质/着色器收集，不加载PackedScene，不扫描Spine骨骼/图集；结束记录版本6。此marker只表示这组独立材质绘制完成，不能证明所有真实特效变体已预编译。取消与异常不应写完成标记。候选正在实机验证，不宣称已消除所有首击停顿。

新版装机回执：用户保存后覆盖安装成功；中文进度页已截图验证（device-preparation-cjk.png），本轮可选材质准备耗时43364ms，108shader完成。perf_trace_on启用时frame-timing.log保留>=80ms帧间隔与管线增量，已从真实iPad读回。当前初始化/准备日志不能充当战斗性能验收；等待实际出牌复现。

## 最终用户验收

用户已确认飞行模式并关闭Wi-Fi后，保存退出、彻底关闭、重新打开、继续存档和声音正常。iPad mini7 / iPadOS27已实现本地原生离线运行。战斗样本截图约60FPS，用户本轮暂未复现明显卡顿；不承诺所有未来场景都无首次特效编译停顿。当前安装保留，不卸载、不再修改。开发描述文件北京时间2026-10-24 00:53到期，需届时重新签名。
