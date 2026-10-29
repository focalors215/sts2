package com.godot.game.online;

import android.content.Context;
import android.content.SharedPreferences;

import com.godot.game.BuildConfig;

import java.io.File;

/** 联机小屋的启动器侧设置（昵称、frp 服务器）。默认服务器来自构建时的 BuildConfig，同 iPad STS2FrpDefaults.h。 */
public final class OnlineRoomPreferences {
	private static final String NAME = "sts2_online_room";
	private static final String KEY_NICKNAME = "nickname";
	private static final String KEY_SERVER = "server";
	private static final String KEY_SERVER_PORT = "server_port";
	private static final String KEY_TOKEN = "token";
	public static final int NICKNAME_MAX = 16;

	private OnlineRoomPreferences() {
	}

	private static SharedPreferences prefs(Context context) {
		return context.getApplicationContext().getSharedPreferences(NAME, Context.MODE_PRIVATE);
	}

	public static String nickname(Context context) {
		String value = prefs(context).getString(KEY_NICKNAME, "");
		return value == null || value.trim().isEmpty() ? "玩家" : value.trim();
	}

	public static void setNickname(Context context, String nickname) {
		String value = nickname == null ? "" : nickname.trim();
		if (value.length() > NICKNAME_MAX) {
			value = value.substring(0, NICKNAME_MAX);
		}
		prefs(context).edit().putString(KEY_NICKNAME, value).apply();
	}

	public static OnlineRoomManager.ServerConfig server(Context context) {
		SharedPreferences prefs = prefs(context);
		return new OnlineRoomManager.ServerConfig(
			prefs.getString(KEY_SERVER, BuildConfig.STS2_FRP_DEFAULT_SERVER),
			prefs.getInt(KEY_SERVER_PORT, BuildConfig.STS2_FRP_DEFAULT_SERVER_PORT),
			prefs.getString(KEY_TOKEN, BuildConfig.STS2_FRP_DEFAULT_TOKEN));
	}

	public static void setServer(Context context, String host, int port, String token) {
		prefs(context).edit()
			.putString(KEY_SERVER, host == null ? "" : host.trim())
			.putInt(KEY_SERVER_PORT, port > 0 && port <= 65535 ? port : OnlineRoomProtocol.DEFAULT_SERVER_PORT)
			.putString(KEY_TOKEN, token == null ? "" : token)
			.apply();
	}

	public static OnlineRoomManager manager(Context context) {
		Context app = context.getApplicationContext();
		File binary = new File(app.getApplicationInfo().nativeLibraryDir, "libfrpc.so");
		return OnlineRoomManager.get(binary, new File(app.getFilesDir(), "online-room"));
	}
}
