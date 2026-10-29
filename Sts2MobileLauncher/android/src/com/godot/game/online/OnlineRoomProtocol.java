package com.godot.game.online;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * 在线房间协议，与 iPad 启动器（sts2-ios STS2RoomService / FrpBridge bridge.go）一致：
 * 中心 frp 服务器上第 i 个槽位把房主的游戏 UDP 端口映射到服务器 UDP (FIRST_GAME_PORT + i)，
 * 并在服务器 TCP (FIRST_CARD_PORT + i) 上发布一张 JSON「房间卡片」。加入方逐个探测卡片端口即可列出房间，
 * 服务器不需要额外软件。三端共用这套端口和字段，互相能看到对方的房间。
 */
public final class OnlineRoomProtocol {
	/** 游戏自带 ENet 房主端口（Android 兼容包与 iPad 默认都是 33771）。 */
	public static final int GAME_PORT = 33771;
	/** 服务器 UDP：游戏端口映射起点（frps allowPorts）。 */
	public static final int FIRST_GAME_PORT = 33771;
	/** 服务器 TCP：房间卡片端口起点（frps allowPorts）。 */
	public static final int FIRST_CARD_PORT = 34771;
	public static final int SLOT_COUNT = 20;
	public static final int SCAN_TIMEOUT_MS = 2500;
	public static final int MAX_CARD_BYTES = 8192;
	public static final int DEFAULT_SERVER_PORT = 7000;

	private OnlineRoomProtocol() {
	}

	public static String gameProxyName(int slot) {
		return "sts2-room-" + slot + "-game";
	}

	public static String cardProxyName(int slot) {
		return "sts2-room-" + slot + "-card";
	}

	/** 房主发布的卡片；字段与 iPad 相同（v / name / host / version / continuing / created / slot / port）。 */
	public static JSONObject buildCard(String nickname, String version, boolean continuing, int slot, long createdEpochSeconds) throws JSONException {
		JSONObject card = new JSONObject();
		card.put("v", 1);
		card.put("name", nickname + "的房间");
		card.put("host", nickname);
		card.put("version", version == null || version.isEmpty() ? "unknown" : version);
		card.put("continuing", continuing);
		card.put("created", createdEpochSeconds);
		card.put("slot", slot);
		card.put("port", FIRST_GAME_PORT + slot);
		return card;
	}

	/**
	 * 解析某个槽位读到的卡片；不是 JSON 对象就返回 null（例如房主进程已退出、frp 端口只剩空连接）。
	 * 可加入的端口只按槽位推算，从不信任卡片里写的端口。
	 */
	public static Room parseCard(int slot, String raw) {
		if (raw == null || slot < 0 || slot >= SLOT_COUNT) {
			return null;
		}
		JSONObject card;
		try {
			card = new JSONObject(raw.trim());
		} catch (JSONException exception) {
			return null;
		}
		String name = card.optString("name", "");
		String version = card.optString("version", "");
		Object nameValue = card.opt("name");
		Object versionValue = card.opt("version");
		return new Room(
			slot,
			nameValue instanceof String && !name.isEmpty() ? name : "未命名房间",
			card.opt("host") instanceof String ? card.optString("host") : "",
			versionValue instanceof String && !version.isEmpty() ? version : "unknown",
			card.optBoolean("continuing", false),
			card.opt("created") instanceof Number ? card.optLong("created") : 0L,
			FIRST_GAME_PORT + slot
		);
	}

	public static List<Room> sortBySlot(List<Room> rooms) {
		List<Room> sorted = new ArrayList<>(rooms);
		Collections.sort(sorted, (a, b) -> Integer.compare(a.slot, b.slot));
		return sorted;
	}

	/** 未被占用的槽位，按顺序最多取 limit 个（同 iPad：扫描后从前三个空位依次尝试）。 */
	public static List<Integer> freeSlots(List<Room> rooms, int limit) {
		boolean[] taken = new boolean[SLOT_COUNT];
		for (Room room : rooms) {
			if (room.slot >= 0 && room.slot < SLOT_COUNT) {
				taken[room.slot] = true;
			}
		}
		List<Integer> free = new ArrayList<>();
		for (int slot = 0; slot < SLOT_COUNT && free.size() < limit; slot++) {
			if (!taken[slot]) {
				free.add(slot);
			}
		}
		return free;
	}

	/** TOML basic string：转义反斜杠、引号和控制字符（同 iPad STS2FrpTunnel）。 */
	public static String tomlString(String value) {
		StringBuilder out = new StringBuilder("\"");
		String text = value == null ? "" : value;
		for (int i = 0; i < text.length(); i++) {
			char c = text.charAt(i);
			if (c == '"' || c == '\\') {
				out.append('\\').append(c);
			} else if (c < 0x20 || c == 0x7f) {
				out.append(String.format(Locale.ROOT, "\\u%04X", (int)c));
			} else {
				out.append(c);
			}
		}
		return out.append('"').toString();
	}

	/** frpc 配置：一条 UDP 游戏映射 + 一条 TCP 卡片映射；状态通过只监听本机的 frpc 管理接口读取。 */
	public static String buildFrpcConfig(String serverAddr, int serverPort, String token, int slot, int localGamePort, int localCardPort, int adminPort, String adminUser, String adminPassword) {
		StringBuilder toml = new StringBuilder();
		toml.append("serverAddr = ").append(tomlString(serverAddr)).append('\n');
		toml.append("serverPort = ").append(serverPort).append('\n');
		toml.append("loginFailExit = true\n");
		toml.append("auth.method = \"token\"\n");
		toml.append("auth.token = ").append(tomlString(token)).append('\n');
		toml.append("webServer.addr = \"127.0.0.1\"\n");
		toml.append("webServer.port = ").append(adminPort).append('\n');
		toml.append("webServer.user = ").append(tomlString(adminUser)).append('\n');
		toml.append("webServer.password = ").append(tomlString(adminPassword)).append('\n');
		toml.append("log.to = \"console\"\nlog.level = \"info\"\nlog.disablePrintColor = true\n");
		appendProxy(toml, gameProxyName(slot), "udp", localGamePort, FIRST_GAME_PORT + slot);
		appendProxy(toml, cardProxyName(slot), "tcp", localCardPort, FIRST_CARD_PORT + slot);
		return toml.toString();
	}

	private static void appendProxy(StringBuilder toml, String name, String type, int localPort, int remotePort) {
		toml.append("\n[[proxies]]\n");
		toml.append("name = ").append(tomlString(name)).append('\n');
		toml.append("type = ").append(tomlString(type)).append('\n');
		toml.append("localIP = \"127.0.0.1\"\n");
		toml.append("localPort = ").append(localPort).append('\n');
		toml.append("remotePort = ").append(remotePort).append('\n');
	}

	/** 远程端口或映射名被占用：换下一个空槽位重试。 */
	public static boolean isSlotTaken(String message) {
		String lower = message == null ? "" : message.toLowerCase(Locale.ROOT);
		return lower.contains("already") || lower.contains("port unavailable") || message != null && message.contains("占用");
	}

	/** 常见 frp 失败加上中文提示，保留原文便于排查（同 iPad TunnelError）。 */
	public static String describeFrpError(String message) {
		String raw = message == null || message.isEmpty() ? "连接服务器超时" : message;
		String lower = raw.toLowerCase(Locale.ROOT);
		String[][] hints = {
			{ "token", "令牌（token）与服务器不一致。" },
			{ "port not allowed", "服务器不允许该远程端口（检查 frps 的 allowPorts）。" },
			{ "already", "远程端口或映射名已被占用：可能有其他房主在用，或上次连接未释放（约 1 分钟后重试）。" },
			{ "port unavailable", "服务器上该远程端口已被占用。" },
			{ "connection refused", "连不上 frp 服务器：检查地址、端口，以及服务器防火墙/安全组。" },
			{ "eof", "连接被服务器或网络中断：检查端口是否为 frps 端口、是否被代理软件拦截。" },
			{ "timeout", "连接 frp 服务器超时：检查网络和服务器防火墙/安全组。" },
		};
		for (String[] hint : hints) {
			if (lower.contains(hint[0])) {
				return hint[1] + "\n（" + raw + "）";
			}
		}
		return raw;
	}

	public static final class Room {
		public final int slot;
		public final String name;
		public final String host;
		public final String version;
		public final boolean continuing;
		public final long createdEpochSeconds;
		public final int port;

		public Room(int slot, String name, String host, String version, boolean continuing, long createdEpochSeconds, int port) {
			this.slot = slot;
			this.name = name;
			this.host = host;
			this.version = version;
			this.continuing = continuing;
			this.createdEpochSeconds = createdEpochSeconds;
			this.port = port;
		}
	}
}
