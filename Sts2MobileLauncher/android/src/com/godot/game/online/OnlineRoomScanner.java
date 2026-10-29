package com.godot.game.online;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/** 并行探测服务器上的全部卡片端口（同 iPad bridge.go Sts2RoomScan）。 */
public final class OnlineRoomScanner {
	private OnlineRoomScanner() {
	}

	public static List<OnlineRoomProtocol.Room> scan(String server, int timeoutMs) {
		List<OnlineRoomProtocol.Room> rooms = new ArrayList<>();
		if (server == null || server.trim().isEmpty()) {
			return rooms;
		}
		String host = server.trim();
		ExecutorService pool = Executors.newFixedThreadPool(OnlineRoomProtocol.SLOT_COUNT, runnable -> {
			Thread thread = new Thread(runnable, "sts2-room-scan");
			thread.setDaemon(true);
			return thread;
		});
		try {
			List<Future<OnlineRoomProtocol.Room>> results = new ArrayList<>();
			for (int slot = 0; slot < OnlineRoomProtocol.SLOT_COUNT; slot++) {
				final int current = slot;
				results.add(pool.submit(() -> OnlineRoomProtocol.parseCard(current, readCard(host, OnlineRoomProtocol.FIRST_CARD_PORT + current, timeoutMs))));
			}
			for (Future<OnlineRoomProtocol.Room> result : results) {
				try {
					OnlineRoomProtocol.Room room = result.get(timeoutMs * 2L + 1000L, TimeUnit.MILLISECONDS);
					if (room != null) {
						rooms.add(room);
					}
				} catch (Exception ignored) {
					result.cancel(true);
				}
			}
		} finally {
			pool.shutdownNow();
		}
		return OnlineRoomProtocol.sortBySlot(rooms);
	}

	static String readCard(String host, int port, int timeoutMs) {
		try (Socket socket = new Socket()) {
			socket.connect(new InetSocketAddress(host, port), timeoutMs);
			socket.setSoTimeout(timeoutMs);
			InputStream in = socket.getInputStream();
			ByteArrayOutputStream out = new ByteArrayOutputStream();
			byte[] buffer = new byte[1024];
			int read;
			while (out.size() < OnlineRoomProtocol.MAX_CARD_BYTES && (read = in.read(buffer, 0, Math.min(buffer.length, OnlineRoomProtocol.MAX_CARD_BYTES - out.size()))) > 0) {
				out.write(buffer, 0, read);
			}
			return out.toString(StandardCharsets.UTF_8.name());
		} catch (IOException exception) {
			return null;
		}
	}
}
