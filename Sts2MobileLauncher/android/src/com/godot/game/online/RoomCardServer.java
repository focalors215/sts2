package com.godot.game.online;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/** 在 127.0.0.1 上给每个 TCP 连接写一次房间卡片后关闭（同 iPad bridge.go Sts2RoomServe），由 frp 暴露到服务器。 */
public final class RoomCardServer {
	private ServerSocket socket;
	private volatile byte[] card = new byte[0];

	public synchronized int start(String cardJson) throws IOException {
		card = cardJson.getBytes(StandardCharsets.UTF_8);
		if (socket == null) {
			ServerSocket server = new ServerSocket();
			server.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0));
			socket = server;
			Thread thread = new Thread(() -> acceptLoop(server), "sts2-room-card");
			thread.setDaemon(true);
			thread.start();
		}
		return socket.getLocalPort();
	}

	public synchronized void stop() {
		if (socket != null) {
			try {
				socket.close();
			} catch (IOException ignored) {
			}
			socket = null;
		}
	}

	private void acceptLoop(ServerSocket server) {
		while (!server.isClosed()) {
			Socket client;
			try {
				client = server.accept();
			} catch (IOException closed) {
				return;
			}
			byte[] data = card;
			Thread writer = new Thread(() -> {
				try (Socket connection = client; OutputStream out = connection.getOutputStream()) {
					connection.setSoTimeout(5000);
					out.write(data);
					out.flush();
				} catch (IOException ignored) {
				}
			}, "sts2-room-card-client");
			writer.setDaemon(true);
			writer.start();
		}
	}
}
