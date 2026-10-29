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

	interface Callback<T> {
		void onResult(T result, String error);
	}

	static final class Room {
		final String name;
		final String version;
		final boolean continuing;
		final int slot;
		final int port;

		Room(String name, String version, boolean continuing, int slot) {
			this.name = name;
			this.version = version;
			this.continuing = continuing;
			this.slot = slot;
			this.port = FIRST_GAME_PORT + slot;
		}
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
		} catch (Exception ignored) {
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
			callback.onResult(null, context.getString(R.string.online_not_configured));
			return;
		}
		String nickname = getNickname();
		boolean continuing = hasMultiplayerSave();
		String version = gameVersion();
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
				error = tryStartRoom(slot, nickname, version, continuing);
				if (error == null) {
					Room room = new Room(context.getString(R.string.online_room_name_format, nickname), version, continuing, slot);
					main.post(() -> callback.onResult(room, null));
					return;
				}
				if (!isTakenError(error)) {
					break;
				}
			}
			FrpBridge.roomStopServe();
			String message = error;
			main.post(() -> callback.onResult(null, message));
		});
	}

	/** One-shot action read (and deleted) by the compat pack's RemoteRoomPatches on the main menu. */
	void writePendingAction(JSONObject action) throws IOException {
		File file = new File(context.getFilesDir(), PENDING_ACTION);
		File temp = new File(file.getPath() + ".tmp");
		FileBrowserSupport.writeTextFile(temp, action.toString());
		if (!temp.renameTo(file)) {
			throw new IOException("Unable to write " + file);
		}
	}

	void clearPendingAction() {
		new File(context.getFilesDir(), PENDING_ACTION).delete();
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
				JSONObject info = entry == null ? null : entry.optJSONObject("info");
				int slot = entry == null ? -1 : entry.optInt("slot", -1);
				if (info == null || slot < 0 || slot >= SLOT_COUNT) {
					continue;
				}
				// The joinable port is derived from the slot, never trusted from the card.
				String name = info.optString("name", "");
				rooms.add(new Room(name.isEmpty() ? context.getString(R.string.online_unnamed_room) : name, info.optString("version", "unknown"), info.optBoolean("continuing", false), slot));
			}
		} catch (Exception ignored) {
		}
		Collections.sort(rooms, (a, b) -> Integer.compare(a.slot, b.slot));
		return rooms;
	}

	// Runs on the worker thread. Returns null on success, otherwise a user-facing error.
	private String tryStartRoom(int slot, String nickname, String version, boolean continuing) {
		JSONObject card = new JSONObject();
		try {
			card.put("v", 1);
			card.put("name", context.getString(R.string.online_room_name_format, nickname));
			card.put("host", nickname);
			card.put("version", version);
			card.put("continuing", continuing);
			card.put("created", System.currentTimeMillis() / 1000L);
			card.put("slot", slot);
			card.put("port", FIRST_GAME_PORT + slot);
		} catch (Exception exception) {
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
			+ "auth.token = " + toml(BuildConfig.FRP_TOKEN) + "\n"
			+ "log.to = " + toml(new File(context.getCacheDir(), "frpc.log").getAbsolutePath()) + "\n"
			+ "log.level = \"info\"\nlog.maxDays = 1\n"
			+ proxy(gameProxy, "udp", LOCAL_GAME_PORT, FIRST_GAME_PORT + slot)
			+ proxy(cardProxy, "tcp", cardPort, FIRST_CARD_PORT + slot);
		FrpBridge.stop();
		File configFile = new File(new File(context.getNoBackupFilesDir(), "frp"), "frpc.toml");
		try {
			FileBrowserSupport.writeTextFile(configFile, config);
		} catch (IOException exception) {
			return exception.getMessage();
		}
		String startError = FrpBridge.start(configFile.getAbsolutePath());
		if (startError != null) {
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
					return describe(detail.isEmpty() ? context.getString(R.string.online_frp_timeout) : detail);
				}
			}
			if (running == 2) {
				return null;
			}
			SystemClock.sleep(300);
		}
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
