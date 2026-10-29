# iOS 资源 PCK 运行时加载桥

`ResourcePackPatches.EnterTreePrefix` 静态织入 `NGame._EnterTree` 的开头，在原方法和既有 ShaderWarmup postfix 之前读取启动器配置。NativeAOT 不运行 DLL MOD、Harmony 或 MOD 初始化器；此桥只调用 Godot 的 `ProjectSettings.LoadResourcePack`。

## 输入契约

原生导入器先检查包为 resource-only PCK，然后将被启用项按顺序写入 `Documents/Launcher/config.json` 根层 `resourceMods`：

```json
{
  "schemaVersion": 1,
  "resourceMods": [
    {
      "id": "原生导入器生成的64位SHA256标识",
      "path": "Launcher/Mods/<id>/payload/example.pck",
      "sha256": "PCK文件内容的64位十六进制SHA256"
    }
  ]
}
```

配置还可包含 network 等字段，桥只读，不改写配置。数组顺序就是挂载顺序，`replaceFiles:true` 表示后续包对同一资源路径具有覆盖顺序；实际生效还取决于资源是否已经缓存。

运行时逐项执行：

1. 验证非空 ID，拒绝重复 ID。
2. 路径相对于 Documents，兼容同一目录内的绝对路径；必须严格位于 `Documents/Launcher/Mods/` 内，扩展名为 `.pck`。拒绝 `.`、`..`、反斜杠、空字符和目录外路径。
3. 从 Documents 本身到目标文件逐层拒绝 symlink/reparse point，包含目录链接和悬空链接。
4. 要求 SHA256 是 64 位十六进制，流式计算文件内容哈希。缺失、读取错误、哈希不匹配都明确失败，不吞成空哈希或视为成功。
5. 只有 `ProjectSettings.LoadResourcePack(path, replaceFiles:true)` 返回 true 才记录 loaded；返回 false 或抛异常记录 failed，并继续尝试后续项。

资源包不进行目录扫描或资产预载，不调用任何程序集加载 API。原生导入器负责 resource-only 准入；运行时哈希验证确保加载的文件内容与导入记录一致，不能用手写配置替代准入检查。

## 实际状态

运行时原子写入 `Documents/Launcher/mod-load-status.json`，启动器下次读取展示最近一次加载结果：

```json
{
  "schemaVersion": 1,
  "completed": true,
  "updatedAtUtc": "2026-10-18T00:00:00+00:00",
  "entries": [
    { "id": "example", "status": "loaded", "error": "", "sha256": "..." },
    { "id": "broken", "status": "failed", "error": "Resource pack SHA256 mismatch.", "sha256": "..." }
  ],
  "loadedIds": ["example"],
  "error": ""
}
```

- `loadedIds` 只包含本轮实际收到 Godot 成功返回值的 ID，不能把配置中的已启用当作已加载。
- 启动时先写 `completed:false`，每项结束后更新；整个尝试完成后才为 true。进程中断时可留下 false，不能解释为全部完成。
- 单项错误放在 `entries[].error`；配置解析或根层 schema 错误放在根 `error`。
- 找不到配置或没有 resourceMods 时，写入完成的空列表。
- 临时文件使用同目录唯一文件名和 CreateNew，落盘后替换目标。状态路径也拒绝 symlink；写入失败会写真实错误日志，不能据此声称状态已保存。

包失败、配置失败和状态写入失败都不修改存档，也不阻止游戏原启动流程。已挂载成功的包不能通过后续失败回滚，因此多包失败时可能是部分加载；实际列表反映这一点。游戏本次进程只尝试一次，下一次启动才重新读取启用项。

## 验证范围与限制

这是资源包挂载桥，不代表任意 PCK MOD 兼容。`NGame` 主场景在 `_EnterTree` 之前已经实例化，一部分资源可能已被 Godot 缓存；这些资源不保证被后挂载包替换。未实现缓存清除、脚本热替换、资源 UID 重映射或全包兼容层。真正可见的替换范围仍须使用受控 fixture 在 Godot/iOS 上验证；`LoadResourcePack=true` 只代表引擎接纳了包。

本地验证仅编译补丁库、运行静态 Weaver 和 Cecil API 检查；新增 1 个 prefix 后预计共 48 hooks（37 既有 + 10 LAN + 1 PCK）。文件路径、哈希、symlink 和状态逻辑可用独立 .NET 测试与 stub Godot 验证，stub 的成功不等于真实 Godot 资源替换成功。运行日志单独写 `ios-export/.work/mod-build.log`、`mod-weaver.log`、`mod-api-verify.log` 与 `mod-unit-test.log`。本次没有运行全 AOT、Xcode 构建或安装。
