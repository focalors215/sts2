package com.godot.game;

import org.json.JSONObject;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.text.Normalizer;

/**
 * Stable multiplayer playerId (doc/architecture/cross-platform-parity.md §3.4), mirroring the
 * compat pack's {@code LanMultiplayerPatches.GetOrCreateLocalPeerId}: the custom player ID when
 * {@code lan_use_custom_player_id} is on, otherwise {@code lan_player_id} in the current profile's
 * settings.save (generated here if missing so launcher and game agree). The value is always in
 * [2, 2^64-1] as an unsigned decimal string; 1 is reserved for the ENet host.
 */
final class OnlineIdentity {
	static final String KEY_PLAYER_ID = "lan_player_id";
	static final String KEY_USE_CUSTOM = "lan_use_custom_player_id";
	static final String KEY_CUSTOM = "lan_custom_player_id";
	private static final BigInteger ULONG_MAX = BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE);
	private static final BigInteger LONG_MASK = BigInteger.ONE.shiftLeft(63).subtract(BigInteger.ONE);

	private OnlineIdentity() {
	}

	/** Reads or creates the playerId in the selected profile's settings.save. */
	static String getOrCreatePlayerId(ExtraSettingsRepository repository) throws Exception {
		JSONObject settings = repository.loadSettingsJson();
		String resolved = resolve(settings);
		if (resolved != null) {
			return resolved;
		}
		String generated = generate(new SecureRandom());
		repository.saveSetting(root -> root.put(KEY_PLAYER_ID, generated));
		LauncherLog.i(LauncherLog.TAG_ONLINE, "生成本机联机玩家 ID " + generated);
		return generated;
	}

	/** Returns the playerId from settings, or null when lan_player_id must be generated. */
	static String resolve(JSONObject settings) {
		if (settings.optBoolean(KEY_USE_CUSTOM, false)) {
			String custom = Normalizer.normalize(settings.optString(KEY_CUSTOM, "").trim(), Normalizer.Form.NFKC);
			if (!custom.isEmpty()) {
				return mapCustom(custom);
			}
		}
		BigInteger saved = parseUnsigned(settings.optString(KEY_PLAYER_ID, ""));
		return saved != null && saved.compareTo(BigInteger.ONE) > 0 ? saved.toString() : null;
	}

	static String mapCustom(String normalized) {
		BigInteger numeric = parseUnsigned(normalized);
		if (numeric != null && numeric.compareTo(BigInteger.ONE) > 0) {
			return numeric.toString();
		}
		try {
			byte[] hash = MessageDigest.getInstance("SHA-256").digest(normalized.getBytes(StandardCharsets.UTF_8));
			BigInteger value = BigInteger.ZERO;
			for (int i = 0; i < 8; i++) {
				value = value.shiftLeft(8).or(BigInteger.valueOf(hash[i] & 0xff));
			}
			value = value.and(LONG_MASK);
			if (value.compareTo(BigInteger.ONE) <= 0) {
				value = value.add(BigInteger.valueOf(2));
			}
			return value.toString();
		} catch (Exception exception) {
			throw new IllegalStateException("SHA-256 unavailable", exception);
		}
	}

	static String generate(SecureRandom random) {
		long value = 0;
		while (value <= 1) {
			value = random.nextLong() & Long.MAX_VALUE;
		}
		return Long.toString(value);
	}

	private static BigInteger parseUnsigned(String text) {
		if (text == null || text.isEmpty() || text.length() > 20) {
			return null;
		}
		for (int i = 0; i < text.length(); i++) {
			if (text.charAt(i) < '0' || text.charAt(i) > '9') {
				return null;
			}
		}
		BigInteger value = new BigInteger(text);
		return value.compareTo(ULONG_MAX) > 0 ? null : value;
	}
}
