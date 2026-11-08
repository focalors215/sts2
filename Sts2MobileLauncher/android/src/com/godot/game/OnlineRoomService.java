package com.godot.game;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextUtils;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Online rooms on the central frp server, compatible with the iPad launcher
 * (STS2RoomService). Slot i maps the host's game UDP port to server UDP
 * (FIRST_GAME_PORT + i) and publishes a JSON room card on server TCP
 * (FIRST_CARD_PORT + i). Clients find rooms by probing the card ports.
 */
final class OnlineRoomService {
	static final int LOCAL_GAME_PORT = 33771; // LanMultiplayerPatches.DefaultPort
	private static final int FIRST_GAME_PORT = 33771; // server UDP, frps allowPorts
	private static final int FIRST_CARD_PORT = 34771; // server TCP, frps allowPorts
	private static final int SLOT_COUNT = 20;
	private static final int SCAN_TIMEOUT_MS = 2500;
	private static final long START_TIMEOUT_MS = 20000;
	private static final String PREFS = "online_rooms";
	private static final String KEY_NICKNAME = "nickname";
	private static final String PENDING_ACTION = "launcher/pending-action.json";
	static final String PLATFORM = "android";
	private static final String TOKEN_FILE = "frp/host-token.txt";

	interface Callback<T> {
		void onResult(T result, String error);
	}

	static final class Room {
		final String name;
		final String version;
		final boolean continuing;
		final int slot;
		final int port;
		/** "android", "windows", "ios" or "" when an older launcher did not write it. */
		final String platform;

		Room(String name, String version, boolean continuing, int slot, String platform) {
			this.name = name;
			this.version = version;
			this.continuing = continuing;
			this.slot = slot;
			this.port = FIRST_GAME_PORT + slot;
			this.platform = platform == null ? "" : platform;
		}
	}

	/** Parses one scanned room card (§3.2); null when unusable. The port always comes from the slot. */
	static Room parseRoomCard(JSONObject info, int slot, String unnamed) {
		if (info == null || slot < 0 || slot >= SLOT_COUNT) {
			return null;
		}
		String name = info.optString("name", "");
		return new Room(name.isEmpty() ? unnamed : name, info.optString("version", "unknown"), info.optBoolean("continuing", false), slot, info.optString("platform", "").trim().toLowerCase(Locale.ROOT));
	}

	/** Room card v1 published by this launcher (§3.2). */
	static JSONObject buildRoomCard(String roomName, String nickname, String version, boolean continuing, long createdSeconds, int slot) throws Exception {
		JSONObject card = new JSONObject();
		card.put("v", 1);
		card.put("name", roomName);
		card.put("host", nickname);
		card.put("version", version);
		card.put("continuing", continuing);
		card.put("created", createdSeconds);
		card.put("slot", slot);
		card.put("port", FIRST_GAME_PORT + slot);
		card.put("platform", PLATFORM);
		return card;
	}

	/** pending-action.json v1 (§3.3); host/port are only written for joins. */
	static JSONObject buildPendingAction(String type, String host, int port, String nickname, String playerId, long createdSeconds) throws Exception {
		JSONObject action = new JSONObject();
		action.put("v", 1);
		action.put("type", type);
		action.put("created", createdSeconds);
		action.put("online", true);
		if (host != null) {
			action.put("host", host);
			action.put("port", port);
		}
		action.put("nickname", nickname);
		if (playerId != null) {
			action.put("playerId", playerId);
		}
		return action;
	}

	private static OnlineRoomService instance;

	private final Context context;
	private final ExecutorService worker = Executors.newSingleThreadExecutor();
	private final Handler main = new Handler(Looper.getMainLooper());

	private OnlineRoomService(Context context) {
		this.context = context.getApplicationContext();
	}

	static synchronized OnlineRoomService get(Context context) {
		if (instance == null) {
			instance = new OnlineRoomService(context);
		}
		return instance;
	}

	static String server() {
		return BuildConfig.FRP_SERVER;
	}

	static boolean isConfigured() {
		return !TextUtils.isEmpty(BuildConfig.FRP_SERVER) && FrpBridge.isAvailable();
	}

	/**
	 * Host token for the frp server (§3.2): never compiled into the APK, asked from the user when a
	 * room is created and kept only in no-backup app storage (not in backups, logs or exports).
	 */
	String getHostToken() {
		File file = new File(context.getNoBackupFilesDir(), TOKEN_FILE);
		if (!file.isFile()) {
			return "";
		}
		try {
			String token = FileBrowserSupport.readTextFile(file).trim();
			LauncherLog.registerSecret(token);
			return token;
		} catch (IOException exception) {
			LauncherLog.w(LauncherLog.TAG_FRP, "读取房主令牌失败", exception);
			return "";
		}
	}

	void setHostToken(String token) throws IOException {
		String trimmed = token == null ? "" : token.trim();
		File file = new File(context.getNoBackupFilesDir(), TOKEN_FILE);
		if (trimmed.isEmpty()) {
			if (file.exists() && !file.delete()) {
				throw new IOException("Unable to delete " + file);
			}
			LauncherLog.i(LauncherLog.TAG_FRP, "已清除房主令牌");
			return;
		}
		LauncherLog.registerSecret(trimmed);
		FileBrowserSupport.writeTextFile(file, trimmed);
		LauncherLog.i(LauncherLog.TAG_FRP, "已保存房主令牌");
	}

	boolean hasHostToken() {
		return !getHostToken().isEmpty();
	}

	/**
	 * Null when the selected launch profile can use online rooms, otherwise a user-facing reason:
	 * the compat pack must be enabled and its target must declare {@code online_rooms}.
	 */
	String onlineSupportProblem() {
		try {
			CompatPackManager compatPackManager = new CompatPackManager(context);
			if (!compatPackManager.isCompatPackEnabled()) {
				return context.getString(R.string.online_compat_disabled);
			}
			CompatPackManager.CompatPack pack = compatPackManager.getSelectedPackIgnoringEnabled();
			if (pack == null) {
				// No pack bound yet: the normal launch flow recommends one before starting the game.
				return null;
			}
			if (!pack.hasCapability(CompatPackManager.CAPABILITY_ONLINE_ROOMS)) {
				return context.getString(R.string.online_compat_unsupported_format, pack.selectionLabel(), pack.targetLabel());
			}
			return null;
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "检查兼容包联机能力失败", exception);
			return null;
		}
	}

	/** Stable playerId of this device (§3.4), shared with the compat pack via settings.save. */
	String playerId() {
		try {
			return OnlineIdentity.getOrCreatePlayerId(new ExtraSettingsRepository(context));
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "读取联机玩家 ID 失败，交给游戏内生成", exception);
			return null;
		}
	}

	String getNickname() {
		return prefs().getString(KEY_NICKNAME, context.getString(R.string.online_default_nickname));
	}

	void setNickname(String nickname) {
		String trimmed = nickname == null ? "" : nickname.trim();
		if (trimmed.isEmpty()) {
			trimmed = context.getString(R.string.online_default_nickname);
		}
		if (trimmed.codePointCount(0, trimmed.length()) > 16) {
			trimmed = trimmed.substring(0, trimmed.offsetByCodePoints(0, 16));
		}
		prefs().edit().putString(KEY_NICKNAME, trimmed).apply();
	}

	/** Version from the selected payload's release_info.json, or "unknown". */
	String gameVersion() {
		try {
			File file = new File(new LaunchProfileManager(context).getSelectedGameDir(), PayloadManager.RELEASE_INFO_FILE_NAME);
			String version = new JSONObject(FileBrowserSupport.readTextFile(file)).optString("version", "");
			return version.isEmpty() ? "unknown" : version;
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "读取游戏版本失败", exception);
			return "unknown";
		}
	}

	boolean hasMultiplayerSave() {
		File account = new LaunchProfileManager(context).getSelectedAccountRootDir();
		File[] profiles = account.listFiles();
		if (profiles == null) {
			return false;
		}
		for (File profile : profiles) {
			if (!profile.getName().startsWith("profile")) {
				continue;
			}
			File save = new File(new File(profile, "saves"), "current_run_mp.save");
			if (save.isFile() || new File(save.getPath() + ".backup").isFile()) {
				return true;
			}
		}
		return false;
	}

	void scanRooms(Callback<List<Room>> callback) {
		worker.execute(() -> {
			List<Room> rooms = scan();
			main.post(() -> callback.onResult(rooms, null));
		});
	}

	/** Takes a free slot, publishes the room card and starts the tunnel. */
	void createRoom(Callback<Room> callback) {
		if (!isConfigured()) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "创建房间失败: 未配置联机服务器或缺少 frp 组件");
			callback.onResult(null, context.getString(R.string.online_not_configured));
			return;
		}
		String token = getHostToken();
		if (token.isEmpty()) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "创建房间失败: 没有房主令牌");
			callback.onResult(null, context.getString(R.string.online_token_required));
			return;
		}
		String nickname = getNickname();
		boolean continuing = hasMultiplayerSave();
		String version = gameVersion();
		LauncherLog.i(LauncherLog.TAG_ONLINE, "创建房间: version=" + version + " continuing=" + continuing + " server=" + server());
		worker.execute(() -> {
			boolean[] taken = new boolean[SLOT_COUNT];
			for (Room room : scan()) {
				taken[room.slot] = true;
			}
			String error = context.getString(R.string.online_server_full);
			for (int slot = 0, tried = 0; slot < SLOT_COUNT && tried < 3; slot++) {
				if (taken[slot]) {
					continue;
				}
				tried++;
				// A slot can be taken between scan and registration; fall through to the next one.
				error = tryStartRoom(slot, nickname, version, continuing, token);
				if (error == null) {
					LauncherLog.i(LauncherLog.TAG_ONLINE, "房间已发布: 槽位 " + slot + "，服务器 UDP " + (FIRST_GAME_PORT + slot) + "，房间卡 TCP " + (FIRST_CARD_PORT + slot));
					Room room = new Room(context.getString(R.string.online_room_name_format, nickname), version, continuing, slot, PLATFORM);
					main.post(() -> callback.onResult(room, null));
					return;
				}
				LauncherLog.w(LauncherLog.TAG_FRP, "槽位 " + slot + " 启动失败: " + error);
				if (!isTakenError(error)) {
					break;
				}
			}
			FrpBridge.roomStopServe();
			LauncherLog.e(LauncherLog.TAG_ONLINE, "创建房间失败: " + error);
			String message = error;
			main.post(() -> callback.onResult(null, message));
		});
	}

	/** One-shot action read (and deleted) by the compat pack's RemoteRoomPatches on the main menu. */
	void writePendingAction(String type, String host, int port) throws Exception {
		JSONObject action = buildPendingAction(type, host, port, getNickname(), playerId(), System.currentTimeMillis() / 1000L);
		File file = new File(context.getFilesDir(), PENDING_ACTION);
		File temp = new File(file.getPath() + ".tmp");
		FileBrowserSupport.writeTextFile(temp, action.toString());
		if (!temp.renameTo(file)) {
			throw new IOException("Unable to write " + file);
		}
		LauncherLog.i(LauncherLog.TAG_ONLINE, "写入联机指令 type=" + type + (host == null ? "" : " target=" + host + ":" + port));
	}

	void clearPendingAction() {
		File file = new File(context.getFilesDir(), PENDING_ACTION);
		if (file.isFile()) {
			if (file.delete()) {
				LauncherLog.i(LauncherLog.TAG_ONLINE, "清除上次遗留的联机指令");
			} else {
				LauncherLog.w(LauncherLog.TAG_ONLINE, "无法删除遗留的联机指令 " + file);
			}
		}
	}

	// Runs on the worker thread.
	private List<Room> scan() {
		List<Room> rooms = new ArrayList<>();
		if (!isConfigured()) {
			return rooms;
		}
		try {
			JSONArray found = new JSONArray(FrpBridge.roomScan(server(), FIRST_CARD_PORT, SLOT_COUNT, SCAN_TIMEOUT_MS));
			for (int i = 0; i < found.length(); i++) {
				JSONObject entry = found.optJSONObject(i);
				// The joinable port is derived from the slot, never trusted from the card.
				Room room = entry == null ? null : parseRoomCard(entry.optJSONObject("info"), entry.optInt("slot", -1), context.getString(R.string.online_unnamed_room));
				if (room != null) {
					rooms.add(room);
				}
			}
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_ONLINE, "扫描房间失败", exception);
		}
		LauncherLog.d(LauncherLog.TAG_ONLINE, "扫描到 " + rooms.size() + " 个房间");
		Collections.sort(rooms, (a, b) -> Integer.compare(a.slot, b.slot));
		return rooms;
	}

	// Runs on the worker thread. Returns null on success, otherwise a user-facing error.
	private String tryStartRoom(int slot, String nickname, String version, boolean continuing, String token) {
		JSONObject card;
		try {
			card = buildRoomCard(context.getString(R.string.online_room_name_format, nickname), nickname, version, continuing, System.currentTimeMillis() / 1000L, slot);
		} catch (Exception exception) {
			LauncherLog.e(LauncherLog.TAG_ONLINE, "生成房间卡失败", exception);
			return exception.getMessage();
		}
		int cardPort = FrpBridge.roomServe(asciiJson(card.toString()));
		if (cardPort <= 0) {
			return context.getString(R.string.online_card_failed);
		}
		String gameProxy = "sts2-room-" + slot + "-game";
		String cardProxy = "sts2-room-" + slot + "-card";
		String config = "serverAddr = " + toml(server()) + "\n"
			+ "serverPort = " + BuildConfig.FRP_SERVER_PORT + "\n"
			+ "loginFailExit = true\n"
			+ "auth.method = \"token\"\n"
			+ "auth.token = " + toml(token) + "\n"
			+ "log.to = " + toml(frpLogFile(context).getAbsolutePath()) + "\n"
			+ "log.level = \"info\"\nlog.maxDays = 1\n"
			+ proxy(gameProxy, "udp", LOCAL_GAME_PORT, FIRST_GAME_PORT + slot)
			+ proxy(cardProxy, "tcp", cardPort, FIRST_CARD_PORT + slot);
		FrpBridge.stop();
		File configFile = new File(new File(context.getNoBackupFilesDir(), "frp"), "frpc.toml");
		try {
			File logDirectory = frpLogFile(context).getParentFile();
			if (logDirectory != null && !logDirectory.isDirectory() && !logDirectory.mkdirs()) {
				LauncherLog.w(LauncherLog.TAG_FRP, "无法创建 frp 日志目录 " + logDirectory);
			}
			FileBrowserSupport.writeTextFile(configFile, config);
		} catch (IOException exception) {
			LauncherLog.e(LauncherLog.TAG_FRP, "写入 frpc.toml 失败", exception);
			return exception.getMessage();
		}
		LauncherLog.i(LauncherLog.TAG_FRP, "启动 frp: 槽位 " + slot + "，" + gameProxy + " / " + cardProxy);
		String startError = FrpBridge.start(configFile.getAbsolutePath());
		if (startError != null) {
			LauncherLog.e(LauncherLog.TAG_FRP, "frp 启动失败: " + startError);
			return describe(context.getString(R.string.online_frp_config_invalid, startError));
		}
		long deadline = SystemClock.elapsedRealtime() + START_TIMEOUT_MS;
		while (true) {
			int running = 0;
			for (String name : new String[] { gameProxy, cardProxy }) {
				JSONObject status;
				try {
					status = new JSONObject(FrpBridge.status(name));
				} catch (Exception exception) {
					LauncherLog.d(LauncherLog.TAG_FRP, "frp 状态无法解析（视为错误）: " + exception);
					status = new JSONObject();
				}
				String state = status.optString("state", "error");
				if ("running".equals(state)) {
					running++;
					continue;
				}
				if (!"starting".equals(state) || SystemClock.elapsedRealtime() > deadline) {
					FrpBridge.stop();
					String detail = status.optString("error", "");
					LauncherLog.e(LauncherLog.TAG_FRP, "代理 " + name + " 未就绪: state=" + state + " error=" + detail);
					return describe(detail.isEmpty() ? context.getString(R.string.online_frp_timeout) : detail);
				}
			}
			if (running == 2) {
				return null;
			}
			SystemClock.sleep(300);
		}
	}

	/** frp's own log (info, 1 day), listed by the log viewer and included in the log export (§5.3). */
	static File frpLogFile(Context context) {
		return new File(new File(context.getFilesDir(), "logs"), "frpc.log");
	}

	/** True when frp rejected the host token; the saved token is then cleared so the next create asks again. */
	static boolean isTokenError(String message) {
		return message != null && message.toLowerCase(Locale.ROOT).contains("token");
	}

	private static boolean isTakenError(String message) {
		String lower = message.toLowerCase(Locale.ROOT);
		return lower.contains("already") || message.contains("占用");
	}

	// Prefix a Chinese hint for the common frp failures; keep frp's own text for diagnosis.
	private String describe(String message) {
		String[][] hints = {
			{ "token", context.getString(R.string.online_hint_token) },
			{ "port not allowed", context.getString(R.string.online_hint_port_not_allowed) },
			{ "already", context.getString(R.string.online_hint_already) },
			{ "port unavailable", context.getString(R.string.online_hint_port_unavailable) },
			{ "connection refused", context.getString(R.string.online_hint_refused) },
			{ "eof", context.getString(R.string.online_hint_eof) },
			{ "timeout", context.getString(R.string.online_hint_timeout) },
		};
		String lower = message.toLowerCase(Locale.ROOT);
		for (String[] hint : hints) {
			if (lower.contains(hint[0])) {
				return hint[1] + "\n(" + message + ")";
			}
		}
		return message;
	}

	private static String proxy(String name, String type, int localPort, int remotePort) {
		return "\n[[proxies]]\nname = " + toml(name) + "\ntype = " + toml(type)
			+ "\nlocalIP = \"127.0.0.1\"\nlocalPort = " + localPort + "\nremotePort = " + remotePort + "\n";
	}

	// TOML basic string: escape backslash, quote and control characters.
	private static String toml(String value) {
		StringBuilder out = new StringBuilder("\"");
		for (int i = 0; i < value.length(); i++) {
			char c = value.charAt(i);
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

	// JNI passes modified UTF-8, which mangles characters outside the BMP; write every
	// non-ASCII char as a JSON unicode escape so the card bytes are plain ASCII.
	private static String asciiJson(String json) {
		StringBuilder out = new StringBuilder(json.length());
		for (int i = 0; i < json.length(); i++) {
			char c = json.charAt(i);
			if (c < 0x80) {
				out.append(c);
			} else {
				out.append(String.format(Locale.ROOT, "\\u%04x", (int)c));
			}
		}
		return out.toString();
	}

	private SharedPreferences prefs() {
		return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
	}
}
