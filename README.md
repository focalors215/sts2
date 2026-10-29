# sts2 启动器

「喵喵零和小鱼的小屋」主题的 STS2 移动端启动器合集，各端使用同一套前端。

| 目录 | 内容 |
|---|---|
| `Sts2MobileLauncher/` | Android 启动器（Godot 4.5.1 mono），以及 `windows/` 下的 Windows 启动器；基于 [ModinMobileSTS/Sts2MobileLauncher](https://github.com/ModinMobileSTS/Sts2MobileLauncher) |
| `sts2-ios/` | iPad / iOS 移植与启动器（`ios-export/launcher/`） |
| `ipad-tools/` | iPad 移植的检查、构建、签名与装机脚本 |
| `design/` | 启动器前端概念图 |

两个子项目都保留了原来的提交历史（以 git subtree 导入）。

## 不在仓库里的内容

- 游戏本体包（如 `sts2-v0.111.0-android-body.zip`）、游戏 DLL / PCK 等资产。
- Android 编译用的运行时参考与工具链（`android-tools/`），iPad 工具链（`ipad-tools/toolchain/`）。
- 本机配置与签名信息：`.env`、`local.properties`、`ios-export/config.sh`、`STS2FrpDefaults.h` 等。
- 设计参考里的第三方图片（来源链接见 `design/house-concepts-20261027/README.md`）。

编译方法分别见 `Sts2MobileLauncher/doc/build/` 和 `sts2-ios/README.md`。
