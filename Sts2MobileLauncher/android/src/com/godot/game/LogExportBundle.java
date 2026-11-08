package com.godot.game;

import android.content.Context;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * One-tap log export contents (doc/architecture/cross-platform-parity.md §5.5): launcher logs,
 * online/frp logs and a {@code diagnostics.json} added next to the latest game logs. Call off the
 * UI thread.
 */
final class LogExportBundle {
	static final String DIAGNOSTICS_NAME = "diagnostics.json";
	private static final Pattern SECRET_KEY = Pattern.compile("(?i).*(token|password|passwd|secret|api_?key|apikey|cookie|credential).*");

	private LogExportBundle() {
	}

	/** {@code sts2-logs-android-yyyyMMdd-HHmmss.zip}. */
	static String bundleFileName(Date time) {
		return "sts2-logs-" + OnlineRoomService.PLATFORM + "-" + new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ROOT).format(time) + ".zip";
	}

	/** Existing launcher.log (+ rotations), online-game.log (+ rotation) and frpc.log under {@code filesDir}. */
	static List<File> launcherSideLogs(File filesDir) {
		List<File> files = new ArrayList<>();
		File logs = new File(filesDir, "logs");
		addIfFile(files, new File(logs, LauncherLog.FILE_NAME));
		for (int index = 1; index < LauncherLog.KEEP_FILES; index++) {
			addIfFile(files, new File(logs, "launcher." + index + ".log"));
		}
		File launcher = new File(filesDir, "launcher");
		addIfFile(files, new File(launcher, "online-game.log"));
		addIfFile(files, new File(launcher, "online-game.1.log"));
		addIfFile(files, new File(logs, "frpc.log"));
		return files;
	}

	static String diagnosticsJson(Context context) {
		JSONObject root = new JSONObject();
		try {
			root.put("platform", OnlineRoomService.PLATFORM);
			root.put("generatedAt", System.currentTimeMillis() / 1000L);
			root.put("osVersion", "Android " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")");
			root.put("deviceModel", Build.MANUFACTURER + " " + Build.MODEL);
			root.put("abis", String.join(",", Build.SUPPORTED_ABIS));
			root.put("launcherVersion", BuildConfig.VERSION_NAME + " (" + BuildConfig.VERSION_CODE + ")");
			root.put("lastStartupMarker", StartupHealthTracker.describePendingLaunch(context));
			putSafely(root, "launchProfile", () -> launchProfile(context));
			putSafely(root, "mods", () -> mods(context));
			putSafely(root, "online", () -> online(context));
			putSafely(root, "settings", () -> redactSettings(new ExtraSettingsRepository(context).loadSettingsJson()));
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_APP, "生成 diagnostics.json 失败", exception);
		}
		try {
			return root.toString(2);
		} catch (Exception exception) {
			return root.toString();
		}
	}

	/** Copy of settings.save without any value whose key looks secret. */
	static JSONObject redactSettings(JSONObject settings) throws Exception {
		JSONObject copy = new JSONObject(settings.toString());
		redactInPlace(copy);
		return copy;
	}

	private static void redactInPlace(JSONObject object) throws Exception {
		List<String> keys = new ArrayList<>();
		for (Iterator<String> iterator = object.keys(); iterator.hasNext(); ) {
			keys.add(iterator.next());
		}
		for (String key : keys) {
			Object value = object.opt(key);
			if (SECRET_KEY.matcher(key).matches()) {
				object.put(key, "***");
			} else if (value instanceof JSONObject) {
				redactInPlace((JSONObject) value);
			} else if (value instanceof JSONArray) {
				JSONArray array = (JSONArray) value;
				for (int i = 0; i < array.length(); i++) {
					if (array.opt(i) instanceof JSONObject) {
						redactInPlace(array.optJSONObject(i));
					}
				}
			}
		}
	}

	private static JSONObject launchProfile(Context context) throws Exception {
		LaunchProfileManager profiles = new LaunchProfileManager(context);
		CompatPackManager compat = new CompatPackManager(context);
		CompatPackManager.CompatPack pack = compat.getSelectedPackIgnoringEnabled();
		JSONObject result = new JSONObject();
		result.put("profileId", profiles.getSelectedProfileId());
		result.put("gameVersion", OnlineRoomService.get(context).gameVersion());
		result.put("compatEnabled", compat.isCompatPackEnabled());
		result.put("compatPack", pack == null ? JSONObject.NULL : pack.selectionLabel());
		result.put("compatVersion", pack == null ? JSONObject.NULL : pack.compatVersion);
		result.put("compatOnlineRooms", pack != null && pack.hasCapability(CompatPackManager.CAPABILITY_ONLINE_ROOMS));
		return result;
	}

	private static JSONObject mods(Context context) throws Exception {
		ExtraSettingsRepository repository = new ExtraSettingsRepository(context);
		JSONObject settings = repository.loadSettingsJson();
		JSONObject result = new JSONObject();
		result.put("loadingEnabled", repository.isModLoadingEnabled(settings));
		JSONArray enabled = new JSONArray();
		JSONArray disabled = new JSONArray();
		for (ExtraSettingsRepository.ModEntry entry : repository.listInstalledModManifests()) {
			String label = entry.modId + (entry.version == null || entry.version.isEmpty() ? "" : "@" + entry.version);
			(repository.isModDisabled(settings, entry) ? disabled : enabled).put(label);
		}
		result.put("enabled", enabled);
		result.put("disabled", disabled);
		return result;
	}

	private static JSONObject online(Context context) throws Exception {
		OnlineRoomService service = OnlineRoomService.get(context);
		JSONObject result = new JSONObject();
		result.put("configured", OnlineRoomService.isConfigured());
		result.put("server", OnlineRoomService.server());
		result.put("nickname", service.getNickname());
		result.put("playerId", service.playerId());
		result.put("hostTokenSaved", service.hasHostToken());
		result.put("compatProblem", service.onlineSupportProblem() == null ? JSONObject.NULL : service.onlineSupportProblem());
		return result;
	}

	private interface JsonSupplier {
		Object get() throws Exception;
	}

	private static void putSafely(JSONObject root, String key, JsonSupplier supplier) throws Exception {
		try {
			root.put(key, supplier.get());
		} catch (Exception exception) {
			LauncherLog.w(LauncherLog.TAG_APP, "diagnostics.json 字段 " + key + " 生成失败", exception);
			root.put(key, "error: " + exception);
		}
	}

	private static void addIfFile(List<File> files, File file) {
		if (file.isFile()) {
			files.add(file);
		}
	}
}
