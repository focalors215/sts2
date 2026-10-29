# iPad 本地运行任务提示词

将用户指定的 ModinMobileSTS/Sts2MobileLauncher 及其合法拥有的本地游戏包适配至 iPadOS。先按证据判断可行性，再实现最小可玩版本；不要把诊断、空壳 UI、成功编译或改扩展名当作成功运行。

## 输入与边界

- 源码位于工作区 `Sts2MobileLauncher/`，保留 `port-mod` 子模块版本并遵循仓库 AGENTS.md。
- 游戏包为工作区 `sts2-v0.111.0-android-body.zip`，不要上传、提交、分发或覆盖其中资源。
- 不更改用户的模型、提供商、登录方式、MCP 或插件配置。
- 用户已明确要求 iPad mini 7 / iPadOS 27 本地离线运行；签名环境待用户完成。不能把目标替换为串流。优先以非越狱设备为目标。

## 阶段一：可复现的可行性检查

1. 克隆源码及子模块，记录 commit；检查本地包的 release_info、runtimeconfig、Android 优化清单。
2. 运行 `ipad-tools/preflight.py`；检查完整 Xcode、iPhoneOS SDK、.NET 和 Godot .NET/导出模板。
3. 追踪 Java/JNI、Godot bootstrap、动态程序集加载、Harmony/MonoMod、FMOD 和 Spine 的调用链。逐项记录 iOS 替代方案与来源。
4. 对照 Godot 4.5 iOS/C# 官方文档核实 AOT 限制。不能假定 Android ELF、AAR、自定义 Mono ABI 或运行时补丁可以用于 iOS。
5. 输出证据、阻塞和验收门槛。遇到运行时架构阻塞时如实报告，不生成伪 IPA。

## 阶段二：先证明运行时，再写启动器

优先审查已克隆到 `sts2-ios/` 的 https://github.com/jhaizhou-ops/sts2-ios ，本次参考 commit 为 `be1144212c7d5ac5d6c78fa56f7cb1d969397389`。其中已有 Cecil 静态织入器、补丁和 NativeAOT 导出工程。不要把上游自述的成功等同于当前 v0.111.0/iPad 已验证。其默认 macOS 游戏路径、PCK 名称、旧方法目标、导出前 Team 配置都需要逐项适配；先验证依赖，再运行会改写产物的构建脚本。用户本地 Android ZIP 是否足够必须据实际程序集和 PCK 证明，不能只改目录名。

1. 明确 iOS 执行策略：验证静态/AOT 兼容补丁方案，或证明合法可部署的解释执行方案能够承载 Godot C# 与所需补丁。不能仅通过关闭编译警告宣称兼容。
2. 用无商业资源的最小样例在目标 iPad 验证 C# 场景注册、调用、反射/泛型和补丁替代机制，记录冷启动日志。动态代码能力不足时重设计兼容层，不默认要求越狱/JIT。
3. 准备与游戏 API/版本匹配的 iOS arm64 Godot、FMOD、Spine 插件并链接验证；只修改加载器不能填补这些依赖。
4. 接入私有本地游戏内容，先达到主菜单、音频与一场战斗可用。成功前不要投入 Steam/创意工坊/云存档功能。

## 阶段三：完成 iPad 可玩版本

1. 增加本地文件导入、内容校验、沙盒路径、横屏触控、安全区域、存档备份与前后台恢复。
2. 用户提供 Team/签名环境后构建并签名安装；不要要求将证书密码写入仓库或对话。
3. 真机验收：断网冷启动，主菜单与中文字体，触控选牌/拖牌，完整战斗及音效，保存退出并重启恢复，前后台/锁屏恢复。记录设备、系统、构建版本、日志和结果。
4. 只有以上通过才报告“iPad 可运行”。交付源码改动、构建步骤、安装包位置与已知限制；未通过时清晰列出实际完成部分和阻塞。

## 参考

- https://github.com/ModinMobileSTS/Sts2MobileLauncher
- https://github.com/jhaizhou-ops/sts2-ios
- https://docs.godotengine.org/en/4.5/tutorials/export/exporting_for_ios.html
- https://docs.godotengine.org/en/4.5/tutorials/scripting/c_sharp/index.html
- https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/

## 2026-10-17 接续状态

已完成工具链、37 处静态织入、ARM64 NativeAOT、FMOD/Spine 原生库、完整 Godot 导出和 Xcode 未签名构建。以 `执行结果.md` 顶部和 `native-build-report.json` 为当前证据；不要再要求用户安装已就绪的工具或重复全部通过的检查。继续任务应先检查设备连接和本机开发签名身份，然后签名装机并采集真机日志。当前没有可引用的真机通过结果。

## 2026-10-17 后续执行回执

用户已授权签名、信任并成功安装到 iPad mini7。旧 Godot 启动在 iPadOS27因缺UIScene触发SIGTRAP，已用真实单场景桥接修复并进入中文菜单与战斗；原始Android项目保持不变。

性能证据：全量场景预热主线程扫描期间约5FPS；跳过后菜单约60、战斗待机59.5FPS。用户反馈首次特效停顿、重复后改善，故默认禁止全量扫描；新候选仅可选独立材质准备、进度遮罩与取消。不能声称全部首次特效已解决，必须实机验证。临时诊断marker5已改为空内容，不能当作真实预热完成。

刷新托管补丁使用 `bash ipad-tools/rebuild-managed.sh`，仅更新真实设备切片；封装framework必须执行 `install_name_tool -id @rpath/sts2.framework/sts2`，否则主程序错误引用@rpath/sts2.dylib。已在脚本修正，并在签名助手增加主程序运行时依赖落地检查。覆盖安装保留存档，绝不卸载。

最终执行结果：用户已验证飞行模式+Wi-Fi关闭后的冷启动、继续存档、声音正常；iPad本地原生离线目标已达成。当前版本保留，性能样本约60FPS。记录在执行结果.md与performance-validation.json。开发签名北京时间2026-10-24 00:53到期，需要续签。
