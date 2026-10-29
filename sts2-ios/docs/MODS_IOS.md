# iOS 启动器 MOD 管理

入口是原生启动器的 **MOD 管理**。页面从“文件”选择本地 ZIP / PCK；导入并校验后可以查看分类、启停、长按调整顺序或确认删除。

2026-10-27 用户取消 Steam 工坊需求，当前页面没有工坊入口，也不会发起工坊下载。未完成的动画 MOD 静态移植没有集成到应用；普通 DLL 仍只归档，不会执行。

## 哪些 MOD 能运行

- 普通 DLL / Harmony MOD：可以下载并归档，默认不能启用。只有应用签名 bundle 中的 `compiled-mods.json` 明确列出完整导入文件集合（每个相对路径、SHA-256、字节数都相同），启动器才显示预编译支持并开放开关。标题、manifest、版本自报和 Documents 中的 JSON 都不能授予能力；没有 capability 文件时保持原有归档行为。
- 资源 PCK：导入器只把可检查的 Godot 4.0–4.5 独立 PCK v2/v3 纳入可启用范围，验证表路径、条目偏移与大小、重复路径、头和目录重叠、未知标记，拒绝加密、稀疏包和删除条目；仅准入非执行的静态资源扩展名 `png/jpg/jpeg/webp/ogg/wav/json/csv/txt`。`.tscn/.tres/.scn/.res` 可含内嵌脚本，import 配置、`project.godot` 及所有未知类型均保留为待验证，不能启用。发现 `.dll/.cs/.gd/.gdc/.gdextension/.dylib/.so/.exe/.wasm` 入口则不启用。白名单表示文件不会作为 Godot 场景/脚本/序列化资源载入，不保证媒体有效或游戏版本兼容。ZIP 中的裸资源文件只归档，不自动假装成 PCK。
- manifest 中声明依赖、游戏版本限制的资源 MOD：保留 manifest，并显示待验证，当前不会自动忽略这些约束后启用。

资源表校验不是游戏兼容性保证。启用只表示请求在**下次冷启动**加载，不代表运行成功。编译 MOD 启用前会重新验证全部导入文件的大小和 SHA-256；资源包仍单独验证 PCK。编译能力列表是只读的签名 bundle 资源，结构为 `{schemaVersion:1,buildId,mods:[{modId,feature,version,sourceSha256,gameVersion,files:[{path,sha256,size}]}]}`。启动器每次读取索引时重新比对完整 `files` 集合；配置只把匹配且启用的条目写入 `compiledMods`。

运行时写入 `Launcher/compiled-mod-load-status.json`。只有状态完整、buildId 与 capability 一致，且条目 id、modId、feature、sourceSha256 全部匹配时，页面才显示“游戏确认已加载”或失败详情。新构建、未完成状态和已禁用结果不会被展示成成功。加载桥和运行时边界见 [MODS_RUNTIME_IOS.md](MODS_RUNTIME_IOS.md)。

例子 `https://steamcommunity.com/sharedfiles/filedetails/?id=3821353824`（More Silent Animations）：实际下载和校验得到 22,450,984 bytes，包含三个 DLL 与 `mod_manifest.json`，没有 PCK。它会出现在“归档 / 待验证”分类，明确需要预编译，不能声称在当前 iOS 应用里即装即用。

## 文件与安全边界

`STS2ModStore` 所有磁盘操作在自身串行队列执行，completion 在主线程调用。`STS2ModsViewController` 使用动态字体、系统颜色、明确错误和空状态。页面只用于游戏启动前的原生启动器，不在运行中注入 MOD。

```text
Documents/Launcher/Mods/
  index.json                    # 用户启用状态、顺序和校验信息
  .staging/<UUID>/               # Store 创建的私有导入/下载暂存目录
  <64位 SHA-256>/
    meta.json                   # 导入时的来源、大小、manifest、逐文件 SHA-256
    payload/                    # 真实下载或解包后的原始文件
Documents/Launcher/config.json  # 根 resourceMods + compiledMods（只含当前匹配并启用项）
App Bundle/compiled-mods.json   # 签名应用内置的编译 MOD 能力；用户 Documents 不参与
```

ID 使用按路径排序的文件列表及其 SHA-256 的稳定散列，展示名称单独来自 manifest / 工坊标题。manifest ID 不直接成为目录组件。启用配置中的路径相对 Documents，如 `Launcher/Mods/<id>/payload/example.pck`，数组顺序就是加载顺序。只有已启用且实际检查通过的资源 PCK 才写入配置。

配置每次写入前重新读取并保留 `network` 及未知字段，缺少 `schemaVersion` 时初始化为 1，已有不支持版本会拒绝且保留原文件。`resourceMods` 和 `compiledMods` 每次根据当前索引重建，禁用或删除会移除对应授权记录。JSON 文件单独原子替换。共享配置写入由 `NSFileManager.defaultManager` 的进程内同步锁保护；索引与配置不是跨文件数据库事务，磁盘错误会显示，不会静默成功。

取消、下载失败、重复安装或导入失败后，会通过 Store 验证并删除本次工坊专用暂存目录；成功导入后同样执行清理（目录已消费时无操作）。下载结果必须是 Store 创建的 `.staging` 直接子目录，拒绝任意目录、符号链接、路径穿越和特殊文件。文档选择器支持外部 ZIP/PCK，通过 security-scoped access 读入并复制到私有暂存，结束即释放访问。ZIP 重用 `STS2ZipArchive` 的安全子集。PCK / ZIP 输入上限 512 MB，解包后总量上限 1 GB、文件数上限 10,000；逐文件及 PCK 保存 SHA-256，启用前重新核验 PCK。较大或未知格式的 MOD 会报错或保留为待验证，不能绕过检查启用。

## 验证

无需游戏或网络的合成测试：

```sh
xcrun --sdk macosx clang++ -DSTS2_MODSTORE_TESTING -fobjc-arc -fblocks -std=c++17 \
  -framework Foundation -framework CoreFoundation \
  ios-export/launcher/STS2ModStore.mm \
  ios-export/launcher/STS2ZipArchive.mm \
  ios-export/launcher/tests/STS2ModStoreTests.mm -lz -o /tmp/sts2-mod-store-tests
/tmp/sts2-mod-store-tests
```

覆盖首次配置初始化、不支持 schema 保留、多 PCK 独立路径和哈希、嵌入 GDScript 的场景拒绝、失败安装暂存清理、独立 PCK v2/v3、SHA-256、资源启用、未知字段保留、DLL 默认禁用、Documents capability 伪造拒绝、缺少能力、完整文件集合/错误哈希门禁、启用前 payload 重验、编译启停和删除、PCK 内代码/穿越/加密、依赖与版本门禁、符号链接、无效索引、重复包及顺序。
