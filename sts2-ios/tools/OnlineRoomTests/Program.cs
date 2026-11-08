using STS2MobileIos.Patches;

var failures = 0;
void Check(bool ok, string name) { Console.WriteLine((ok ? "[OK] " : "[FAIL] ") + name); if (!ok) failures++; }

var now = DateTimeOffset.FromUnixTimeSeconds(1762650000);
string Json(string body) => "{" + body + "}";

var join = PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762649990,\"online\":true,\"host\":\"frp.example.com\",\"port\":33774,\"nickname\":\"喵喵零\",\"playerId\":\"1234567890123\""), now);
Check(join.Error == null && join.Type == "join" && join.Host == "frp.example.com" && join.Port == 33774 && join.Online && join.PlayerId == "1234567890123" && join.Nickname == "喵喵零", "完整 join 指令");

var host = PendingAction.Parse(Json("\"v\":1,\"type\":\"host\",\"created\":1762649900,\"online\":false"), now);
Check(host.Error == null && host.Type == "host" && !host.Online, "局域网 host 指令（600 s 内）");

var numericId = PendingAction.Parse(Json("\"v\":1,\"type\":\"host\",\"created\":1762650000,\"playerId\":1234567890123"), now);
Check(numericId.PlayerId == "1234567890123", "playerId 数字形式也接受");

var expired = PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762649399,\"host\":\"a\",\"port\":1"), now);
Check(expired.Expired && expired.Error != null, "超过 600 s 过期");
var boundary = PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762649400,\"host\":\"a\",\"port\":1"), now);
Check(!boundary.Expired && boundary.Error == null, "正好 600 s 未过期");
var future = PendingAction.Parse(Json("\"v\":1,\"type\":\"host\",\"created\":1762651000"), now);
Check(future.Expired, "时钟回拨/未来时间超过 600 s 也丢弃");
var legacy = PendingAction.Parse(Json("\"type\":\"join\",\"host\":\"a\",\"port\":1"), now);
Check(legacy.Expired, "旧格式缺 created 按过期处理");

Check(PendingAction.Parse("not json", now).Error != null && !PendingAction.Parse("not json", now).Expired, "非 JSON 报错");
Check(PendingAction.Parse("[]", now).Error != null, "非对象报错");
Check(PendingAction.Parse(Json("\"v\":2,\"type\":\"host\",\"created\":1762650000"), now).Error?.Contains("版本") == true, "未知版本报错");
Check(PendingAction.Parse(Json("\"v\":1,\"type\":\"spectate\",\"created\":1762650000"), now).Error?.Contains("未知") == true, "未知 type 报错");
Check(PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762650000,\"host\":\"\",\"port\":33771"), now).Error != null, "空地址报错");
Check(PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762650000,\"host\":\"a b\",\"port\":33771"), now).Error != null, "地址含空白报错");
Check(PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762650000,\"host\":\"a\",\"port\":70000"), now).Error != null, "端口越界报错");
Check(PendingAction.Parse(Json("\"v\":1,\"type\":\"join\",\"created\":1762650000,\"host\":\"a\",\"port\":0"), now).Error != null, "端口 0 报错");

var time = new DateTimeOffset(2026, 11, 9, 12, 34, 56, 789, TimeSpan.FromHours(8));
var line = OnlineRoomLog.Format(time, 'I', "加入 frp.example.com:33774", null);
Check(line == "2026-11-09T12:34:56.789+08:00 I [online] 加入 frp.example.com:33774", "行格式：" + line);
Exception error;
try { throw new InvalidOperationException("token=abc123 失败"); } catch (Exception e) { error = e; }
var multi = OnlineRoomLog.Format(time, 'E', "开房失败 auth.token = \"s3cret\"", error);
Check(multi.StartsWith("2026-11-09T12:34:56.789+08:00 E [online] 开房失败 auth.token = \"***\" | InvalidOperationException: token=*** 失败\n    at "), "异常行与堆栈缩进");
Check(!multi.Contains("s3cret") && !multi.Contains("abc123"), "令牌已脱敏");
Check(OnlineRoomLog.Redact("curl -H Authorization: Bearer sk-live-1").Contains("sk-live") == false, "Bearer 令牌脱敏");
Check(OnlineRoomLog.Redact("{\"apiKey\":\"k-1\",\"password\":\"p\"} Authorization: Bearer") == "{\"apiKey\":\"***\",\"password\":\"***\"} Authorization: ***", "JSON 与头部脱敏");

// 规范 §3.4 续局身份：先 playerId 再 1。
const ulong me = 1234567890123;
Check(MultiplayerIdentity.Resolve(new ulong[] { 1, me }, me, out var id1) == MultiplayerIdentity.Role.Joiner && id1 == me, "存档含 1 和本机 → 加入方（不能顶替房主）");
Check(MultiplayerIdentity.Resolve(new ulong[] { 1, 99 }, me, out var id2) == MultiplayerIdentity.Role.Host && id2 == 1, "存档含 1 不含本机 → 房主");
Check(MultiplayerIdentity.Resolve(new ulong[] { 7, 99 }, me, out var id3) == MultiplayerIdentity.Role.Mismatch && id3 == 0, "都不在 → 不匹配");
Check(MultiplayerIdentity.Resolve(new ulong[] { 1 }, 1, out var id4) == MultiplayerIdentity.Role.Host && id4 == 1, "非法本机 ID=1 不会被当作加入方");
Check(!MultiplayerIdentity.IsValidPlayerId(0) && !MultiplayerIdentity.IsValidPlayerId(1) && MultiplayerIdentity.IsValidPlayerId(2) && MultiplayerIdentity.IsValidPlayerId(long.MaxValue) && !MultiplayerIdentity.IsValidPlayerId((ulong)long.MaxValue + 1), "playerId 范围 [2, 2^63-1]");

Console.WriteLine(failures == 0 ? "ALL PASSED" : $"{failures} FAILED");
return failures == 0 ? 0 : 1;
