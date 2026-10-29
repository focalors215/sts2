package com.godot.game;

import java.nio.charset.StandardCharsets;

/** JNI binding for libsts2frp.so (android/frp-bridge, official frp client in-process). */
final class FrpBridge {
	private static Throwable loadError;

	static {
		try {
			System.loadLibrary("sts2frp");
		} catch (Throwable error) {
			loadError = error;
		}
	}

	private FrpBridge() {
	}

	static boolean isAvailable() {
		return loadError == null;
	}

	/** Returns null on success, otherwise an error message. */
	static String start(String configPath) {
		return text(nativeStart(configPath));
	}

	/** JSON {"state","error","remoteAddr"}; state is starting, running, error or stopped. */
	static String status(String proxyName) {
		return text(nativeStatus(proxyName));
	}

	static void stop() {
		nativeStop();
	}

	/** Serves the room card on a loopback TCP port; returns the port or -1. */
	static int roomServe(String info) {
		return nativeRoomServe(info);
	}

	static void roomStopServe() {
		nativeRoomStopServe();
	}

	/** JSON array of {"slot","info"} for the card ports that answered. */
	static String roomScan(String server, int firstPort, int count, int timeoutMs) {
		return text(nativeRoomScan(server, firstPort, count, timeoutMs));
	}

	private static String text(byte[] utf8) {
		return utf8 == null ? null : new String(utf8, StandardCharsets.UTF_8);
	}

	private static native byte[] nativeStart(String configPath);
	private static native byte[] nativeStatus(String proxyName);
	private static native void nativeStop();
	private static native int nativeRoomServe(String info);
	private static native void nativeRoomStopServe();
	private static native byte[] nativeRoomScan(String server, int firstPort, int count, int timeoutMs);
}
