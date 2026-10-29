package com.godot.game.online;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

@RunWith(RobolectricTestRunner.class)
public class OnlineRoomProtocolTest {
	@Test
	public void cardMatchesIpadFieldsAndPortComesFromSlot() throws Exception {
		JSONObject card = OnlineRoomProtocol.buildCard("小鱼", "v0.111.0", true, 3, 1761700000L);
		assertEquals(1, card.getInt("v"));
		assertEquals("小鱼的房间", card.getString("name"));
		assertEquals("小鱼", card.getString("host"));
		assertEquals(33774, card.getInt("port"));
		// 卡片里写错端口也不信任：只按槽位推算。
		card.put("port", 1);
		OnlineRoomProtocol.Room room = OnlineRoomProtocol.parseCard(3, card.toString());
		assertNotNull(room);
		assertEquals(33774, room.port);
		assertEquals("v0.111.0", room.version);
		assertTrue(room.continuing);
		assertEquals(1761700000L, room.createdEpochSeconds);
	}

	@Test
	public void invalidCardsAreIgnoredAndMissingFieldsFallBack() {
		assertNull(OnlineRoomProtocol.parseCard(0, ""));
		assertNull(OnlineRoomProtocol.parseCard(0, "not json"));
		assertNull(OnlineRoomProtocol.parseCard(0, "[1,2]"));
		assertNull(OnlineRoomProtocol.parseCard(OnlineRoomProtocol.SLOT_COUNT, "{}"));
		OnlineRoomProtocol.Room room = OnlineRoomProtocol.parseCard(0, "{\"name\": 5}");
		assertEquals("未命名房间", room.name);
		assertEquals("unknown", room.version);
	}

	@Test
	public void freeSlotsSkipTakenOnesInOrder() {
		List<OnlineRoomProtocol.Room> rooms = Arrays.asList(
			new OnlineRoomProtocol.Room(0, "a", "", "v", false, 0, 33771),
			new OnlineRoomProtocol.Room(2, "b", "", "v", false, 0, 33773));
		assertEquals(Arrays.asList(1, 3, 4), OnlineRoomProtocol.freeSlots(rooms, 3));
		assertEquals(OnlineRoomProtocol.SLOT_COUNT, OnlineRoomProtocol.freeSlots(Collections.emptyList(), 99).size());
	}

	@Test
	public void frpcConfigEscapesValuesAndMapsBothPorts() {
		assertEquals("\"a\\\"b\\\\c\\u000A\"", OnlineRoomProtocol.tomlString("a\"b\\c\n"));
		String toml = OnlineRoomProtocol.buildFrpcConfig("1.2.3.4", 7000, "to\"ken", 2, 33771, 40000, 41000, "u", "p");
		assertTrue(toml.contains("serverAddr = \"1.2.3.4\""));
		assertTrue(toml.contains("auth.token = \"to\\\"ken\""));
		assertTrue(toml.contains("loginFailExit = true"));
		assertTrue(toml.contains("webServer.addr = \"127.0.0.1\""));
		assertTrue(toml.contains("name = \"sts2-room-2-game\"\ntype = \"udp\"\nlocalIP = \"127.0.0.1\"\nlocalPort = 33771\nremotePort = 33773"));
		assertTrue(toml.contains("name = \"sts2-room-2-card\"\ntype = \"tcp\"\nlocalIP = \"127.0.0.1\"\nlocalPort = 40000\nremotePort = 34773"));
	}

	@Test
	public void frpErrorsGetChineseHintsAndSlotConflictsAreRetried() {
		assertTrue(OnlineRoomProtocol.describeFrpError("token in login doesn't match").startsWith("令牌"));
		assertTrue(OnlineRoomProtocol.describeFrpError("dial tcp: connection refused").startsWith("连不上"));
		assertEquals("其他错误", OnlineRoomProtocol.describeFrpError("其他错误"));
		assertTrue(OnlineRoomProtocol.isSlotTaken("start error: port already used"));
		assertTrue(OnlineRoomProtocol.isSlotTaken("proxy [x] already exists"));
		assertFalse(OnlineRoomProtocol.isSlotTaken("token mismatch"));
	}

	@Test
	public void frpLogPrefixIsStrippedAndBase64MatchesJdk() {
		assertEquals("connect to server error: token mismatch",
			FrpTunnel.stripLogPrefix("2026-10-29 09:05:41.970 [W] [client/service.go:346] connect to server error: token mismatch"));
		assertEquals("login to the server failed", FrpTunnel.stripLogPrefix("login to the server failed"));
		for (String value : new String[] { "", "a", "ab", "abc", "sts2:0f3a9c" }) {
			assertEquals(java.util.Base64.getEncoder().encodeToString(value.getBytes()), FrpTunnel.base64(value.getBytes()));
		}
	}
}
