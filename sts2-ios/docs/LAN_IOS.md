# iOS ENet 联机（v0.111.0）

此补丁把原多人菜单的「开房」和「加入好友」入口接到游戏自带 ENet/UDP 传输。它没有实现 Steam 好友、邀请、打洞或中继。保存启动器网络配置不代表已连接：只有开房成功或原 `JoinFlow` 握手完成才进入联机状态。

## 操作

1. 在启动器设置昵称、房主地址和 UDP 端口（默认 `33771`）。昵称、地址、端口可在加入页面修改；房主使用启动器配置的端口。
2. 房主从游戏的原多人菜单开房；成功后进入原角色选择、每日或自定义房间。人数上限 4。
3. 其他玩家打开原「加入好友」页面，输入房主的 IP 或主机名，单独填写端口并按「加入」。地址框不解析 `IP:端口`，IPv6 地址无需方括号；端口有独立输入框。
4. 同一 Wi-Fi 下使用房主的局域网地址；访客网络/AP 隔离可能阻止设备互访。iOS 首次请求本地网络访问时需允许。
5. Internet 使用相同 ENet 协议，需要房主 UDP 端口可从公网到达（路由器 UDP 转发、可达公网地址）或双方处于可互通的 VPN。仅知道公网 IP 无法解决运营商 NAT；本补丁不提供中继服务。

普通 Steam PC 客户端仍走其原平台流程，不能据此承诺直接互连。PC/Android 端必须有对应版本的 ENet 开房/加入入口，且双方游戏版本、模型数据库与游戏相关 MOD 必须通过原握手验证。

### 2026-10-27 真机验证

iPad mini 7 与用户的 Android v0.111.0 客户端已完成同一 Wi-Fi 下开房、加入、双方出牌与回合同步，以及保存退出后重新开房续局。日志确认双方版本为 v0.111.0、ModelDb hash 均为 1568834832，原始版本与模型校验保留。最初的 UNKNOWN 来自 iOS 打包遗漏原始 `release_info.json`；补入与原游戏程序集匹配的原文件后解决，没有放宽握手。公网 UDP、VPN 和普通 Steam PC 互通仍未实测。

## 配置与身份

文件为 iOS `Documents/Launcher/config.json`（Godot `user://Launcher/config.json`），schema 1：

```json
{
  "schemaVersion": 1,
  "network": {
    "nickname": "Player",
    "host": "192.168.1.10",
    "port": 33771,
    "playerId": "持久化的非零十进制 UInt64"
  },
  "resourceMods": []
}
```

`resourceMods` 在根层，与 native launcher 一致。读入后保留未知字段，使用同目录临时文件替换进行原子写入；旧补丁误放到 `network.resourceMods` 的数据会迁到根层。网络 ID 首次缺失时随机产生并保存，以后复用；复制配置到另一台设备时应给新设备生成不同 ID，避免同房重复身份。

昵称覆盖本机平台名称查询。原 Null 平台对远端名称仍使用其已有名称表/ID 显示；此补丁未新增昵称同步网络消息，不能承诺远端显示自定义昵称。

随机网络 ID **只用于联机身份**。`UserDataPathProvider` 的 3 个路径入口把默认本地账号重新指定为 `1`，所以已有 `Documents/default/1` 单机、配置和多人存档仍在原位置；显式指定其他平台或其他账号的路径保持其参数语义。没有移动、复制或删除任何既有存档。

多人续局要求稳定 ID 与存档内玩家 ID 匹配。若不匹配，补丁在原 canonicalization 之前返回明确的读取失败，并保留文件，防止游戏把身份不匹配的存档重命名为损坏文件。恢复创建该存档时的 `network.playerId` 后再启动（旧 Null 平台房主可能是 `"1"`）；**不要从多名玩家中猜选或重写 NetId**。备份配置时同时备份存档。

## 实现边界

- 开房：`NetHostGameService(PeerVersionInfo.LocalDefault()).StartENetHost(port, 4)`，然后调用原房间初始化。
- 加入：原 `NJoinFriendScreen.JoinGameAsync(ENetClientConnectionInitializer(stableId, host, port))`。v0.111.0 原方法自行创建 `NetClientGameService(PeerVersionInfo.LocalDefault())` 和 `JoinFlow`，负责取消、错误弹窗及转场；关闭页面仍运行原取消逻辑。
- 续局：原读取、模型恢复与角色身份验证；缺少匹配 ID 时拒绝继续。
- 2 个私有字段通过 .NET `UnsafeAccessor` 以固定类型直接访问，Cecil 探针检查字段和类型；没有 Harmony、运行时装载程序集或 JIT。
- 不修改消息 ID、序列化、版本校验或 ModelDb 校验。实际成功加载的资源 PCK 按顺序计算 SHA-256 指纹，并追加到原版游戏相关 MOD 清单；加载顺序不同也会被识别。资源 MOD 联机要求另一端采用相同指纹规则，不能仅在两端安装同名资源包。初次跨平台验收应关闭两端所有 MOD。

## 离线验证

在仓库上级目录（含 `ipad-tools`、`sts2-ios`）运行，使用本地 .NET 9。设置 `DOTNET_ROOT`、`DOTNET_CLI_HOME`、`NUGET_PACKAGES` 指向现有工具链即可。只编译补丁与探针，不需 NativeAOT 或 Xcode：

```sh
ipad-tools/toolchain/dotnet/dotnet build sts2-ios/src/STS2MobileIos/STS2MobileIos.csproj --no-restore -o sts2-ios/ios-export/.work/lan-hooks
ipad-tools/toolchain/dotnet/dotnet sts2-ios/ios-export/.work/weaver-build/bin/STS2Weaver/release/STS2Weaver.dll sts2-ios/game-refs/sts2.dll sts2-ios/ios-export/.work/lan-hooks/STS2MobileIos.dll sts2-ios/src/STS2MobileIos/manifest.json sts2-ios/ios-export/.work/lan-hooks/sts2.lan.woven.dll
ipad-tools/toolchain/dotnet/dotnet run --project sts2-ios/tools/LanApiProbe/LanApiProbe.csproj -- sts2-ios/game-refs/sts2.dll --verify sts2-ios/ios-export/.work/lan-hooks/STS2MobileIos.dll sts2-ios/ios-export/.work/lan-hooks/sts2.lan.woven.dll sts2-ios/src/STS2MobileIos/manifest.json
```

当前整合清单应得到 49 个钩子（既有 37 + LAN 10 + 资源加载与握手 2），探针检查所有 manifest 目标都有织入调用和私有字段类型匹配。日志独立写 `lan-build.log`、`lan-weaver.log`、`lan-api-verify.log`，不覆盖 AOT 日志。

离线通过不等于设备联通。当前已完成的真机项目见上方验收记录；仍需单独覆盖重名/重复 ID、各类版本与 MOD 不匹配、异常断线，以及 UDP 公网转发和 VPN。局域网验收结果不代表公网打洞或中继已实现。

## 远程联机（frp 穿透）

不在同一网络时，房主用启动器内置的 frp 客户端把本机 ENet UDP 端口映射到一台 frp 服务器，朋友直接连服务器的远程端口。游戏协议、握手和版本校验均不变；只有房主需要 frp，加入方不需要。

- 客户端是官方 frp v0.71.1 库（`src/FrpBridge`，Go c-archive），在进程内运行，iOS 不允许起 frpc 子进程。
- 启动器「联机小屋 → 远程联机」：开关“我当房主时开启远程穿透”、frp 服务器地址、服务器端口（frps `bindPort`）、令牌、远程 UDP 端口。保存在 `config.json` 的 `network.frp`。
- 房主开启开关后点“开始游戏”：先连 frp 并等待服务器确认映射（最多 20 秒），成功后弹出朋友需要填写的地址和端口，再进入游戏开房。失败可选择仅局域网继续。
- 加入方点“我要加入：填入远程房间地址”，把 `host/port` 设为服务器地址和远程端口，并关闭自己的穿透开关，然后在游戏「加入好友」页加入。
- 映射为 `udp`：`127.0.0.1:<启动器 UDP 端口>` → `<服务器>:<远程端口>`，映射名固定 `sts2-enet-udp`。一个远程端口同时只能有一位房主；异常退出后服务器约 1 分钟才释放旧映射。
- 服务器要求：frps 在 `bindPort` 上对外监听（TCP），远程 UDP 端口在 `allowPorts` 内；云服务器安全组/防火墙需放行这两项。客户端默认启用 TLS 连接 frps（frps ≥ 0.50 自动兼容）。
- 应用退到后台时 iOS 会挂起 frp 连接，回前台后 frp 自动重连；联机途中切后台可能导致掉线。
- 个人服务器默认值放在 `ios-export/launcher/STS2FrpDefaults.h`（git 忽略，模板为 `STS2FrpDefaults.example.h`）；frp 运行配置写入 `Library/Application Support/frp/frpc.toml`，日志 `Library/Caches/frpc.log`。

构建：`bash tools/build-frp-bridge.sh` 生成 `ios-export/prebuilt/frp/libfrpbridge.a`，再运行 `python3 ipad-tools/apply-scene-bridge.py` 加入链接参数（libfrpbridge.a、`-lresolv`、Security、CoreFoundation）。

### 2026-10-28 验证

本机用同版本 frps（127.0.0.1）回环测试 `STS2FrpTunnel`：连接后 UDP 回显 5/5、同端口重启、错误令牌、端口不在 allowPorts 四项均符合预期；带 frp 的未签名 Xcode Release 构建通过。iPad 真机与公网服务器尚未验证：测试时 `123.56.157.107:7000` 直连返回“拒绝连接”，需先确认服务器上 frps 的监听端口与防火墙。
