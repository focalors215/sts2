# iPad 移植检查

当前项目尚不能在 iPad 本地运行。这里的工具只生成诊断报告，不生成 IPA，也不安装或修改系统工具链。

在工作区根目录执行（Python 3.9+，无第三方依赖）：

```sh
python3 ipad-tools/preflight.py \
  --payload sts2-v0.111.0-android-body.zip \
  --repo Sts2MobileLauncher \
  --output ipad-tools/preflight-report.json
```

退出码 `2` 表示移植前置条件阻塞，`1` 表示输入无效。本版本不会返回“可运行”。脚本读取 ZIP 目录、小型 JSON、PCK 文件头，不解压或执行游戏；大文件 CRC/哈希、PCK 内嵌插件、DLL API 与真机兼容性尚需后续验证。可用环境变量 `DOTNET_BIN` 和 `GODOT_BIN` 指定本地工具；通过工具存在/版本检查也不能证明导出模板或运行时兼容。

本目录位于上游仓库之外，保存本机诊断和任务提示词；游戏资源继续留在原 ZIP 中。执行提示词见 `iPad移植提示词.md`，当前执行结果见 `执行结果.md`。

2026-10-17 已在工作区内准备 .NET、Godot、iOS 模板并完成 37 处织入和 ARM64 NativeAOT 编译；工具版本与下载摘要见 `toolchain-lock.json`，构建结果见 `managed-build-report.json`。私有游戏构建副本位于 `sts2-ios/` 的 ignored 目录；原 ZIP 不变。

`python3 ipad-tools/export-unsigned.py` 在插件到齐后导出本地 Xcode 工程。它临时使用无账号的 Team 占位值和 ad-hoc 库签名，仅生成工程，之后清空占位 Team；不会生成可装机的开发者签名。导出结束（含失败）会恢复上游预设与项目配置。成功后用真实游戏 PCK 替换驱动壳 PCK，并加入无自定义 FMOD 插件的入口实现。签名和真机验证仍是后续步骤。
