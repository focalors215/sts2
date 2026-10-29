package com.godot.game.online;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assume.assumeTrue;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 用真实 frps/frpc 联调开房、扫描、槽位冲突与令牌错误。需要本机（非 Android）版 frp v0.71.1：
 * STS2_FRP_TEST_DIR=<含 frps 与 frpc 的目录>；未设置时跳过。frps 只监听 127.0.0.1，测试结束即退出。
 */
@RunWith(RobolectricTestRunner.class)
public class OnlineRoomFrpIntegrationTest {
	private static final int SERVER_PORT = 17123;
	private File frpDir;
	private File work;
	private Process frps;

	@Before
	public void startServer() throws Exception {
		String dir = System.getenv("STS2_FRP_TEST_DIR");
		assumeTrue("STS2_FRP_TEST_DIR not set", dir != null && new File(dir, "frps").canExecute());
		frpDir = new File(dir);
		work = Files.createTempDirectory("sts2-frp-test").toFile();
		File config = new File(work, "frps.toml");
		try (FileWriter writer = new FileWriter(config)) {
			writer.write("bindAddr = \"127.0.0.1\"\nbindPort = " + SERVER_PORT + "\nauth.method = \"token\"\nauth.token = \"secret\"\n"
				+ "allowPorts = [ { start = 33771, end = 33790 }, { start = 34771, end = 34790 } ]\n");
		}
		frps = new ProcessBuilder(new File(frpDir, "frps").getAbsolutePath(), "-c", config.getAbsolutePath())
			.redirectErrorStream(true).redirectOutput(new File(work, "frps.log")).start();
		Thread.sleep(800);
	}

	@After
	public void stopServer() {
		if (frps != null) {
			frps.destroy();
		}
	}

	@Test
	public void hostsAreListedAndSecondHostTakesNextSlot() throws Exception {
		OnlineRoomManager first = manager("a");
		OnlineRoomManager second = manager("b");
		try {
			OnlineRoomManager.Snapshot one = open(first, "secret", "喵喵零");
			assertEquals(one.error, OnlineRoomManager.Phase.OPEN, one.phase);
			assertEquals(0, one.room.slot);
			OnlineRoomManager.Snapshot two = open(second, "secret", "小鱼");
			assertEquals(two.error, OnlineRoomManager.Phase.OPEN, two.phase);
			assertEquals(1, two.room.slot);
			List<OnlineRoomProtocol.Room> rooms = OnlineRoomScanner.scan("127.0.0.1", 1500);
			assertEquals(2, rooms.size());
			assertEquals("喵喵零的房间", rooms.get(0).name);
			assertEquals(33772, rooms.get(1).port);
			first.closeRoom();
			Thread.sleep(1500);
			assertEquals(1, OnlineRoomScanner.scan("127.0.0.1", 1500).size());
		} finally {
			first.closeRoom();
			second.closeRoom();
			Thread.sleep(500);
		}
	}

	@Test
	public void slotTakenWithoutCardFallsThroughToNextSlot() throws Exception {
		// 只占用槽位 0 的 UDP 远程端口、不发布卡片：扫描认为 0 号空闲，注册时冲突，应改用 1 号。
		File squatter = new File(work, "squat.toml");
		try (FileWriter writer = new FileWriter(squatter)) {
			writer.write("serverAddr = \"127.0.0.1\"\nserverPort = " + SERVER_PORT + "\nauth.method = \"token\"\nauth.token = \"secret\"\n"
				+ "[[proxies]]\nname = \"squat\"\ntype = \"udp\"\nlocalIP = \"127.0.0.1\"\nlocalPort = 1\nremotePort = 33771\n");
		}
		Process squat = new ProcessBuilder(new File(frpDir, "frpc").getAbsolutePath(), "-c", squatter.getAbsolutePath())
			.redirectErrorStream(true).redirectOutput(new File(work, "squat.log")).start();
		OnlineRoomManager manager = manager("c");
		try {
			Thread.sleep(1200);
			OnlineRoomManager.Snapshot result = open(manager, "secret", "房主");
			assertEquals(result.error, OnlineRoomManager.Phase.OPEN, result.phase);
			assertEquals(1, result.room.slot);
		} finally {
			manager.closeRoom();
			squat.destroy();
			Thread.sleep(500);
		}
	}

	@Test
	public void wrongTokenReportsHint() throws Exception {
		OnlineRoomManager manager = manager("d");
		OnlineRoomManager.Snapshot result = open(manager, "wrong", "房主");
		assertEquals(OnlineRoomManager.Phase.FAILED, result.phase);
		assertNotNull(result.error);
		assertTrue(result.error, result.error.startsWith("令牌"));
	}

	private OnlineRoomManager manager(String name) throws IOException {
		File dir = new File(work, name);
		assertTrue(dir.mkdirs());
		return new OnlineRoomManager(new File(frpDir, "frpc"), dir);
	}

	private static OnlineRoomManager.Snapshot open(OnlineRoomManager manager, String token, String nickname) throws InterruptedException {
		CountDownLatch done = new CountDownLatch(1);
		AtomicReference<OnlineRoomManager.Snapshot> result = new AtomicReference<>();
		manager.addListener(snapshot -> {
			if (snapshot.phase == OnlineRoomManager.Phase.OPEN || snapshot.phase == OnlineRoomManager.Phase.FAILED) {
				result.compareAndSet(null, snapshot);
				done.countDown();
			}
		});
		manager.createRoom(new OnlineRoomManager.ServerConfig("127.0.0.1", SERVER_PORT, token), nickname, "v0.111.0", false);
		assertTrue("timed out", done.await(40, TimeUnit.SECONDS));
		return result.get();
	}
}
