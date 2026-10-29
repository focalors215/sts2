# 联机小屋：在线房间与局域网直连

Android 启动器的「联机小屋」页面移植自 iPad 启动器（`sts2-ios/ios-export/launcher/` 的 `renderNetworkPage`、`STS2RoomService`、`STS2FrpTunnel`）。两端用同一台 frp 服务器、同一套槽位端口和同一种房间卡片，**安卓和 iPad 可以互相看到并加入对方的房间**。

游戏内的联机仍是游戏自带的 ENet/UDP 传输：兼容包 `LanMultiplayerPatches` 已提供开房（固定 UDP 33771）和「加入好友」地址输入；启动器只负责把房间暴露到服务器、列出房间，并把要加入的地址写进设置。没有改动消息协议、版本校验或 ModelDb 校验，双方游戏版本与玩法 MOD 仍需一致。

## 页面

入口：插画主页的「联机小屋」热区、宽屏侧栏「联机小屋」、窄屏顶部「联机」标签。

| 区块 | 作用 |
| --- | --- |
| 创建房间 | 扫描服务器，取前三个空槽位依次尝试：发布房间卡片 → 用 frpc 把本机 UDP 33771 和卡片端口映射到服务器。成功后提示进入游戏，在「多人游戏」里开房（有多人存档时继续）。房间开放期间有前台通知，可在通知里关房。 |
| 在线房间 | 列出服务器上的全部房间（名称、版本、创建时间、是否续局）。版本与本机游戏本体不同的房间不能加入；自己的房间标为「我的房间」。 |
| 加入 | 把服务器地址和该房间的端口写入当前存档账号 `settings.save` 的 `lan_join_host` / `lan_join_port`，确认后启动游戏；游戏的「多人游戏 → 加入好友」页面会带出这两个值，点「加入」即可。 |
| 局域网直连 | 显示本机局域网 IPv4 地址和端口 33771；也可以手动填写房主地址/端口加入（同样写入上面两个设置）。不需要服务器。 |
| 联机设置 | 昵称（房间名显示为「昵称的房间」，最多 16 字）、frp 服务器地址、服务器端口（frps `bindPort`）、令牌。保存在启动器 SharedPreferences `sts2_online_room`，不进 `settings.save`。 |

与 iPad 的差别：iPad 的游戏补丁会读取启动器写的 `pending-action.json` 自动开房/加入；Android 兼容包（`port-mod`，独立仓库）暂未实现这一步，所以进入游戏后需要玩家自己点一次「开房」或「加入」，地址已经预先填好。

## 房间协议（与 iPad 一致）

- 第 `i` 个槽位（`0 ≤ i < 20`）：服务器 UDP `33771 + i` ← 房主游戏 UDP 33771；服务器 TCP `34771 + i` ← 房主本机的房间卡片端口。
- 房间卡片：房主在 `127.0.0.1` 上开一个 TCP 端口，每个连接写一次 JSON 后关闭：

  ```json
  {"v":1,"name":"小鱼的房间","host":"小鱼","version":"v0.111.0","continuing":false,"created":1761700000,"slot":3,"port":33774}
  ```

- 扫描：并行连接 20 个卡片端口（超时 2.5 秒），读到 JSON 对象就是一个房间；可加入的端口只按槽位推算，不信任卡片里的 `port`。
- frp 映射名：`sts2-room-<i>-game`（udp）、`sts2-room-<i>-card`（tcp）。槽位在扫描后被别人占用时（frps 返回 already used 等），换下一个空槽位。

## frp 服务器要求

只有房主连 frp 服务器；加入方直接连服务器的 UDP 端口，不需要 frp。frps 最小配置：

```toml
bindPort = 7000
auth.method = "token"
auth.token = "换成你的令牌"
allowPorts = [ { start = 33771, end = 33790 }, { start = 34771, end = 34790 } ]
```

云服务器安全组/防火墙放行 TCP `bindPort`、UDP 33771–33790、TCP 34771–34790。客户端与 iPad 一样默认用 TLS 连接 frps（frps ≥ 0.50 自动兼容）。

默认服务器可以在构建时写进 APK（与 iPad 被 git 忽略的 `STS2FrpDefaults.h` 作用相同），在 `.env` 中设置：

```bash
STS2_FRP_DEFAULT_SERVER=frp.example.com
STS2_FRP_DEFAULT_SERVER_PORT=7000
STS2_FRP_DEFAULT_TOKEN=...
```

它们只作为默认值进入 `BuildConfig`，玩家仍可在「联机设置」里修改。不要把个人服务器地址和令牌提交进仓库。

## frp 客户端

- iPad 不能起子进程，所以把 frp 编成静态库放进 App；Android 直接运行**官方** frp v0.71.1 `android_arm64` 发行版里的 `frpc`（与 iPad 同版本）。
- `tools/android/stage-frpc.sh` 下载官方压缩包并校验固定的 SHA-256，把 `frpc` 放成 `android/libs/{debug,dev,release}/arm64-v8a/libfrpc.so`（gitignored）。`sync-runtime-from-references.sh` 末尾会自动调用它，所以导入版/直装版打包脚本都会带上。缓存目录默认 `.agent/cache/frp/`，也可以用 `STS2_FRPC_BINARY` 指向本地文件。
- 工程 minSdk 24，Gradle 使用 legacy 原生库打包，安装后 `libfrpc.so` 解压在 `nativeLibraryDir`，可直接执行。APK 因此增大约 16 MB。
- 运行时：配置写到 `<files>/online-room/frpc.toml`（含令牌，仅本应用可读），输出写到 `<files>/online-room/frpc.log`。frpc 的管理接口只监听 `127.0.0.1`、随机端口和随机口令，启动器通过它读取两条映射的状态（最多等 20 秒）。服务器地址先在 Java 里用系统 DNS 解析成 IP 再交给 frpc，不依赖 frpc 自己在 Android 上的 DNS 解析。
- frpc 意外退出（断网且重连失败、服务器重启）时，房间标为断开并撤下卡片；新进程启动时会清理上次被杀进程留下的 frpc。

## 代码位置

| 文件 | 作用 |
| --- | --- |
| `android/src/com/godot/game/NetworkPage.java` | 联机小屋页面。 |
| `android/src/com/godot/game/online/OnlineRoomProtocol.java` | 端口、卡片格式、frpc 配置生成、错误提示（与 iPad 对齐）。 |
| `android/src/com/godot/game/online/OnlineRoomScanner.java` | 并行扫描卡片端口。 |
| `android/src/com/godot/game/online/RoomCardServer.java` | 本机房间卡片服务。 |
| `android/src/com/godot/game/online/FrpTunnel.java` | frpc 子进程、状态轮询、残留进程清理。 |
| `android/src/com/godot/game/online/OnlineRoomManager.java` | 开房/关房状态机与槽位重试。 |
| `android/src/com/godot/game/online/OnlineRoomService.java` | 房间开放期间的前台服务（`dataSync`）与通知。 |
| `android/src/com/godot/game/online/OnlineRoomPreferences.java` | 昵称与服务器设置。 |
| `tools/android/stage-frpc.sh` | 下载并校验官方 frpc。 |

## 测试

- `android/test/com/godot/game/online/OnlineRoomProtocolTest.java`：卡片格式、端口推算、无效卡片、空槽位、TOML 转义、错误提示与槽位冲突判断。
- `android/test/com/godot/game/online/OnlineRoomFrpIntegrationTest.java`：用真实 frps/frpc 联调两位房主分到 0/1 号槽位、扫描与关房、槽位被占时换下一个、令牌错误。需要本机版 frp v0.71.1，设置 `STS2_FRP_TEST_DIR=<含 frps 与 frpc 的目录>`，否则跳过。
- 开发时还用 iPad 端真实的 `bridge.go`（编成 Linux 静态库）与 Android 代码在同一台 frps 上互扫，双方都能看到对方的房间。

尚未在真机上验证：Android 前台服务下 frpc 的长时间稳定性、iPad 与 Android 通过公网服务器的实际对局、运营商网络下的 UDP 质量。
