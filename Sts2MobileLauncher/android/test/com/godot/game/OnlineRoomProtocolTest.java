package com.godot.game;

import android.app.Application;

import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.TimeZone;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

/** Room card (§3.2), pending action (§3.3), playerId (§3.4) and log export (§5.5) contracts. */
@RunWith(RobolectricTestRunner.class)
@Config(application = Application.class, sdk = 35, shadows = AndroidLinuxTestShadow.class)
public class OnlineRoomProtocolTest {
	@Rule public TemporaryFolder temporary = new TemporaryFolder();

	@Test public void roomCardCarriesPlatformAndRoundTrips() throws Exception {
		JSONObject card = OnlineRoomService.buildRoomCard("喵喵零的房间", "喵喵零", "v0.107.1", true, 1762650000L, 3);
		assertEquals(1, card.getInt("v"));
		assertEquals("android", card.getString("platform"));
		assertEquals(33774, card.getInt("port"));
		assertEquals(3, card.getInt("slot"));
		assertEquals(1762650000L, card.getLong("created"));

		OnlineRoomService.Room room = OnlineRoomService.parseRoomCard(card, 3, "?");
		assertEquals("喵喵零的房间", room.name);
		assertEquals("v0.107.1", room.version);
		assertTrue(room.continuing);
		assertEquals("android", room.platform);
		assertEquals(33774, room.port);
	}

	@Test public void roomCardPortComesFromSlotAndUnknownFieldsAreIgnored() throws Exception {
		JSONObject foreign = new JSONObject("{\"v\":1,\"name\":\"\",\"version\":\"v0.111.0\",\"port\":1,\"platform\":\"Windows\",\"extra\":{\"a\":1}}");
		OnlineRoomService.Room room = OnlineRoomService.parseRoomCard(foreign, 19, "未命名");
		assertEquals(33771 + 19, room.port);
		assertEquals("未命名", room.name);
		assertEquals("windows", room.platform);
		assertEquals("", OnlineRoomService.parseRoomCard(new JSONObject("{\"name\":\"x\"}"), 0, "?").platform);
		assertNull(OnlineRoomService.parseRoomCard(foreign, 20, "?"));
		assertNull(OnlineRoomService.parseRoomCard(null, 1, "?"));
	}

	@Test public void pendingActionMatchesSpecFields() throws Exception {
		JSONObject join = OnlineRoomService.buildPendingAction("join", "frp.example.com", 33774, "喵喵零", "1234567890123", 1762650000L);
		assertEquals(1, join.getInt("v"));
		assertEquals("join", join.getString("type"));
		assertEquals(1762650000L, join.getLong("created"));
		assertTrue(join.getBoolean("online"));
		assertEquals("frp.example.com", join.getString("host"));
		assertEquals(33774, join.getInt("port"));
		assertEquals("喵喵零", join.getString("nickname"));
		assertEquals("1234567890123", join.getString("playerId"));

		JSONObject host = OnlineRoomService.buildPendingAction("host", null, 0, "a", null, 1L);
		assertFalse(host.has("host"));
		assertFalse(host.has("port"));
		assertFalse(host.has("playerId"));
	}

	@Test public void playerIdMatchesCompatPackRules() throws Exception {
		JSONObject settings = new JSONObject();
		assertNull(OnlineIdentity.resolve(settings));
		settings.put(OnlineIdentity.KEY_PLAYER_ID, "1");
		assertNull("1 is reserved for the ENet host", OnlineIdentity.resolve(settings));
		settings.put(OnlineIdentity.KEY_PLAYER_ID, "4242424242");
		assertEquals("4242424242", OnlineIdentity.resolve(settings));

		settings.put(OnlineIdentity.KEY_USE_CUSTOM, true);
		settings.put(OnlineIdentity.KEY_CUSTOM, " 喵喵零 ");
		// SHA-256(NFKC UTF-8) first 8 bytes big-endian & 0x7FFF…, same as LanMultiplayerPatches.MapCustomPeerId.
		assertEquals("6193197929277911612", OnlineIdentity.resolve(settings));
		settings.put(OnlineIdentity.KEY_CUSTOM, "Player One");
		assertEquals("5873324559275431292", OnlineIdentity.resolve(settings));
		settings.put(OnlineIdentity.KEY_CUSTOM, "987654321");
		assertEquals("987654321", OnlineIdentity.resolve(settings));
		settings.put(OnlineIdentity.KEY_CUSTOM, "1");
		assertFalse("1".equals(OnlineIdentity.resolve(settings)));

		SecureRandom random = new SecureRandom();
		for (int i = 0; i < 1000; i++) {
			long value = Long.parseLong(OnlineIdentity.generate(random));
			assertTrue(value > 1);
		}
	}

	@Test public void exportBundleNameAndLauncherSideLogs() throws Exception {
		TimeZone previous = TimeZone.getDefault();
		TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
		try {
			assertEquals("sts2-logs-android-20261109-043456.zip", LogExportBundle.bundleFileName(new Date(1794198896789L)));
		} finally {
			TimeZone.setDefault(previous);
		}
		File files = temporary.newFolder("files");
		File launcherLog = write(files, "logs/launcher.log");
		File rotated = write(files, "logs/launcher.2.log");
		File online = write(files, "launcher/online-game.log");
		File frp = write(files, "logs/frpc.log");
		write(files, "logs/sts2.log");
		List<File> logs = LogExportBundle.launcherSideLogs(files);
		assertEquals(Arrays.asList(launcherLog, rotated, online, frp), logs);
	}

	@Test public void diagnosticsSettingsAreRedacted() throws Exception {
		JSONObject settings = new JSONObject("{\"log_level\":\"info\",\"lan_player_id\":\"42\",\"webdav\":{\"password\":\"p\",\"user\":\"u\"},\"nexus_api_key\":\"k\",\"list\":[{\"refresh_token\":\"t\"}]}");
		JSONObject redacted = LogExportBundle.redactSettings(settings);
		assertEquals("info", redacted.getString("log_level"));
		assertEquals("42", redacted.getString("lan_player_id"));
		assertEquals("***", redacted.getJSONObject("webdav").getString("password"));
		assertEquals("u", redacted.getJSONObject("webdav").getString("user"));
		assertEquals("***", redacted.getString("nexus_api_key"));
		assertEquals("***", redacted.getJSONArray("list").getJSONObject(0).getString("refresh_token"));
		assertEquals("p", settings.getJSONObject("webdav").getString("password"));
	}

	@Test public void frpFilesAreExcludedFromDataExport() {
		File root = new File("/data/user/0/com.megacrit.sts2re");
		assertTrue(ExtraSettingsRepository.isExcludedFromDataExport(root, new File(root, "no_backup/frp")));
		assertTrue(ExtraSettingsRepository.isExcludedFromDataExport(root, new File(root, "no_backup/frp/host-token.txt")));
		assertFalse(ExtraSettingsRepository.isExcludedFromDataExport(root, new File(root, "no_backup/frpx")));
		assertFalse(ExtraSettingsRepository.isExcludedFromDataExport(root, new File(root, "files/logs/frpc.log")));
	}

	private static File write(File root, String relative) throws Exception {
		File file = new File(root, relative);
		file.getParentFile().mkdirs();
		Files.write(file.toPath(), "x".getBytes(StandardCharsets.UTF_8));
		return file;
	}
}
