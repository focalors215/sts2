package com.godot.game.online;

import java.io.File;
import java.io.IOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 在线房间的开房/关房状态（进程内单例）。流程同 iPad STS2RoomService：扫描 → 取前三个空槽位 →
 * 发布房间卡片 → frp 映射游戏端口与卡片端口；槽位在扫描后被别人抢占时换下一个。
 * 回调在后台线程，界面自行切回主线程。
 */
public final class OnlineRoomManager {
	public enum Phase { IDLE, STARTING, OPEN, FAILED }

	public interface Listener {
		void onRoomStateChanged(Snapshot snapshot);
	}

	public static final class Snapshot {
		public final Phase phase;
		public final OnlineRoomProtocol.Room room;
		public final String server;
		public final String error;

		Snapshot(Phase phase, OnlineRoomProtocol.Room room, String server, String error) {
			this.phase = phase;
			this.room = room;
			this.server = server;
			this.error = error;
		}
	}

	public static final class ServerConfig {
		public final String host;
		public final int port;
		public final String token;

		public ServerConfig(String host, int port, String token) {
			this.host = host == null ? "" : host.trim();
			this.port = port > 0 && port <= 65535 ? port : OnlineRoomProtocol.DEFAULT_SERVER_PORT;
			this.token = token == null ? "" : token;
		}

		public boolean isConfigured() {
			return !host.isEmpty();
		}
	}

	private static OnlineRoomManager instance;

	private final FrpTunnel tunnel;
	private final RoomCardServer cardServer = new RoomCardServer();
	private final ExecutorService worker = Executors.newSingleThreadExecutor(runnable -> {
		Thread thread = new Thread(runnable, "sts2-online-room");
		thread.setDaemon(true);
		return thread;
	});
	private final List<Listener> listeners = new CopyOnWriteArrayList<>();
	private volatile Snapshot snapshot = new Snapshot(Phase.IDLE, null, "", null);
	private volatile int generation;

	public OnlineRoomManager(File frpcBinary, File workDir) {
		this.tunnel = new FrpTunnel(frpcBinary, workDir);
	}

	public static synchronized OnlineRoomManager get(File frpcBinary, File workDir) {
		if (instance == null) {
			instance = new OnlineRoomManager(frpcBinary, workDir);
			// 上次进程被杀时可能留下 frpc 子进程（占着服务器上的映射）；新进程先清掉。
			instance.worker.execute(instance.tunnel::killStale);
		}
		return instance;
	}

	public Snapshot snapshot() {
		return snapshot;
	}

	public boolean isTunnelBinaryAvailable() {
		return tunnel.isBinaryAvailable();
	}

	public File frpLogFile() {
		return tunnel.logFile();
	}

	public void addListener(Listener listener) {
		listeners.add(listener);
	}

	public void removeListener(Listener listener) {
		listeners.remove(listener);
	}

	/** 开房：成功时 phase=OPEN，room 为发布出去的卡片。 */
	public void createRoom(ServerConfig server, String nickname, String version, boolean continuing) {
		final int token = ++generation;
		publish(new Snapshot(Phase.STARTING, null, server.host, null));
		worker.execute(() -> {
			try {
				OnlineRoomProtocol.Room room = openRoom(server, nickname, version, continuing, token);
				if (token != generation) {
					closeQuietly();
					return;
				}
				publish(new Snapshot(Phase.OPEN, room, server.host, null));
				startWatchdog(token, server.host);
			} catch (IOException exception) {
				closeQuietly();
				if (token == generation) {
					publish(new Snapshot(Phase.FAILED, null, server.host, describe(exception)));
				}
			}
		});
	}

	/** 关房：结束 frpc 并撤下卡片。 */
	public void closeRoom() {
		generation++;
		publish(new Snapshot(Phase.IDLE, null, snapshot.server, null));
		worker.execute(this::closeQuietly);
	}

	private OnlineRoomProtocol.Room openRoom(ServerConfig server, String nickname, String version, boolean continuing, int token) throws IOException {
		if (!server.isConfigured()) {
			throw new IOException("server_missing");
		}
		// 地址先用系统 DNS 解析成 IP 再交给 frpc，不依赖 Go 程序在 Android 上的 DNS 解析。
		String serverAddr = literal(InetAddress.getByName(server.host));
		List<OnlineRoomProtocol.Room> rooms = OnlineRoomScanner.scan(server.host, OnlineRoomProtocol.SCAN_TIMEOUT_MS);
		List<Integer> slots = OnlineRoomProtocol.freeSlots(rooms, 3);
		if (slots.isEmpty()) {
			throw new IOException("rooms_full");
		}
		IOException last = null;
		for (int i = 0; i < slots.size() && token == generation; i++) {
			int slot = slots.get(i);
			long created = System.currentTimeMillis() / 1000L;
			String card;
			try {
				card = OnlineRoomProtocol.buildCard(nickname, version, continuing, slot, created).toString();
			} catch (org.json.JSONException exception) {
				throw new IOException(exception.getMessage());
			}
			int cardPort = cardServer.start(card);
			try {
				tunnel.start(serverAddr, server.port, server.token, slot, OnlineRoomProtocol.GAME_PORT, cardPort);
				return OnlineRoomProtocol.parseCard(slot, card);
			} catch (IOException exception) {
				last = exception;
				if (!OnlineRoomProtocol.isSlotTaken(exception.getMessage())) {
					break;
				}
			}
		}
		throw last != null ? last : new IOException("cancelled");
	}

	/** frpc 意外退出（断网、服务器重启且重连失败）时把房间标为已断开。 */
	private synchronized void startWatchdog(int token, String server) {
		Thread thread = new Thread(() -> {
			while (token == generation) {
				try {
					Thread.sleep(2000);
				} catch (InterruptedException interrupted) {
					return;
				}
				if (token == generation && !tunnel.isRunning()) {
					String reason = tunnel.lastError();
					closeQuietly();
					if (token == generation) {
						publish(new Snapshot(Phase.FAILED, null, server, OnlineRoomProtocol.describeFrpError(reason.isEmpty() ? "frpc exited" : reason)));
					}
					return;
				}
			}
		}, "sts2-online-room-watchdog");
		thread.setDaemon(true);
		thread.start();
	}

	private void closeQuietly() {
		tunnel.stop();
		cardServer.stop();
	}

	private static String describe(IOException exception) {
		String message = exception.getMessage() == null ? exception.toString() : exception.getMessage();
		switch (message) {
			case "server_missing":
			case "rooms_full":
			case "frp_binary_missing":
			case "cancelled":
				return message;
			default:
				return OnlineRoomProtocol.describeFrpError(message);
		}
	}

	private static String literal(InetAddress address) {
		String host = address.getHostAddress();
		int zone = host.indexOf('%');
		if (address instanceof Inet6Address && zone >= 0) {
			host = host.substring(0, zone);
		}
		return host;
	}

	private void publish(Snapshot next) {
		snapshot = next;
		for (Listener listener : listeners) {
			listener.onRoomStateChanged(next);
		}
	}
}
