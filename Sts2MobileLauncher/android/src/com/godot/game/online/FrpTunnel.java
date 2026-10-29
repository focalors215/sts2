package com.godot.game.online;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Deque;

/**
 * 以子进程运行官方 frpc（APK 内的 libfrpc.so，安装后位于 nativeLibraryDir，可直接执行）。
 * iPad 不能起子进程才把 frp 编进 App；Android 用官方二进制即可，行为与 iPad STS2FrpTunnel 一致：
 * 等待两条映射都进入 running（最多 20 秒），失败时给出 frp 原文与中文提示。
 */
public final class FrpTunnel {
	public static final long START_TIMEOUT_MS = 20_000L;
	private static final int TAIL_LINES = 40;

	private final File binary;
	private final File workDir;
	private final Deque<String> tail = new ArrayDeque<>();
	private Process process;
	private int adminPort;
	private String adminAuth;

	public FrpTunnel(File binary, File workDir) {
		this.binary = binary;
		this.workDir = workDir;
	}

	public File configFile() {
		return new File(workDir, "frpc.toml");
	}

	public File logFile() {
		return new File(workDir, "frpc.log");
	}

	public boolean isBinaryAvailable() {
		return binary != null && binary.isFile() && binary.canExecute();
	}

	public synchronized boolean isRunning() {
		return process != null && isAlive(process);
	}

	/** 连上 frp 服务器并等两条映射都就绪；失败抛出 IOException（消息为 frp 原文）。 */
	public void start(String serverAddr, int serverPort, String token, int slot, int localGamePort, int localCardPort) throws IOException {
		if (!isBinaryAvailable()) {
			throw new IOException("frp_binary_missing");
		}
		stop();
		killStale();
		if (!workDir.isDirectory() && !workDir.mkdirs()) {
			throw new IOException("Cannot create " + workDir);
		}
		String user = "sts2";
		String password = randomToken();
		int port = freeLoopbackPort();
		String toml = OnlineRoomProtocol.buildFrpcConfig(serverAddr, serverPort, token, slot, localGamePort, localCardPort, port, user, password);
		File config = configFile();
		File temp = new File(workDir, "frpc.toml.tmp");
		try (Writer writer = new OutputStreamWriter(new FileOutputStream(temp), StandardCharsets.UTF_8)) {
			writer.write(toml);
		}
		// 配置里有令牌：只给本应用读。
		temp.setReadable(false, false);
		temp.setReadable(true, true);
		if (!temp.renameTo(config)) {
			config.delete();
			if (!temp.renameTo(config)) {
				throw new IOException("Cannot write " + config);
			}
		}
		ProcessBuilder builder = new ProcessBuilder(binary.getAbsolutePath(), "-c", config.getAbsolutePath());
		builder.directory(workDir);
		builder.redirectErrorStream(true);
		Process started = builder.start();
		synchronized (this) {
			process = started;
			adminPort = port;
			adminAuth = base64((user + ":" + password).getBytes(StandardCharsets.UTF_8));
			tail.clear();
		}
		pumpOutput(started);
		String[] names = { OnlineRoomProtocol.gameProxyName(slot), OnlineRoomProtocol.cardProxyName(slot) };
		long deadline = System.currentTimeMillis() + START_TIMEOUT_MS;
		while (true) {
			if (!isAlive(started)) {
				throw new IOException(lastError());
			}
			ProxyState state = readState(names);
			if (state.error != null) {
				stop();
				throw new IOException(state.error);
			}
			if (state.running == names.length) {
				return;
			}
			if (System.currentTimeMillis() > deadline) {
				String last = lastError();
				stop();
				throw new IOException(last.isEmpty() ? "timeout" : last);
			}
			try {
				Thread.sleep(300);
			} catch (InterruptedException interrupted) {
				stop();
				Thread.currentThread().interrupt();
				throw new IOException("cancelled");
			}
		}
	}

	public synchronized void stop() {
		Process current = process;
		process = null;
		if (current == null) {
			return;
		}
		current.destroy();
		// minSdk 24 没有 waitFor(timeout)：最多等 2 秒让 frpc 退出并释放服务器上的映射。
		for (int i = 0; i < 20 && isAlive(current); i++) {
			try {
				Thread.sleep(100);
			} catch (InterruptedException interrupted) {
				Thread.currentThread().interrupt();
				return;
			}
		}
	}

	/** 应用被系统杀掉时 frpc 子进程可能还活着；按配置文件路径找到并结束它。 */
	public void killStale() {
		String marker = configFile().getAbsolutePath();
		File[] entries = new File("/proc").listFiles();
		if (entries == null) {
			return;
		}
		for (File entry : entries) {
			String name = entry.getName();
			if (!name.chars().allMatch(Character::isDigit)) {
				continue;
			}
			try {
				byte[] raw;
				try (InputStream in = new java.io.FileInputStream(new File(entry, "cmdline"))) {
					raw = readAll(in);
				}
				String cmdline = new String(raw, StandardCharsets.UTF_8).replace('\0', ' ');
				if (cmdline.contains(binary.getName()) && cmdline.contains(marker)) {
					new ProcessBuilder("kill", name).start().waitFor();
				}
			} catch (Exception ignored) {
			}
		}
	}

	private void pumpOutput(Process started) {
		Thread thread = new Thread(() -> {
			try (InputStream in = started.getInputStream();
			     BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
			     OutputStream log = new FileOutputStream(logFile(), false)) {
				String line;
				while ((line = reader.readLine()) != null) {
					log.write((line + "\n").getBytes(StandardCharsets.UTF_8));
					synchronized (tail) {
						tail.addLast(line);
						while (tail.size() > TAIL_LINES) {
							tail.removeFirst();
						}
					}
				}
			} catch (IOException ignored) {
			}
		}, "sts2-frpc-output");
		thread.setDaemon(true);
		thread.start();
	}

	/** frpc 退出时最后一行通常就是原因（如 “login to the server failed: …”）。 */
	public String lastError() {
		synchronized (tail) {
			String fallback = "";
			for (String line : tail) {
				String lower = line.toLowerCase(java.util.Locale.ROOT);
				if (lower.contains("[e]") || lower.contains("[w]") || lower.contains("failed") || lower.contains("error")) {
					fallback = line;
				}
			}
			if (!fallback.isEmpty()) {
				return stripLogPrefix(fallback);
			}
			return tail.isEmpty() ? "" : stripLogPrefix(tail.peekLast());
		}
	}

	static String stripLogPrefix(String line) {
		// "2026-10-29 09:05:41.970 [W] [client/service.go:346] connect to server error: …" → 正文
		String text = line.trim();
		int index = text.lastIndexOf("] ");
		return index >= 0 && text.startsWith("20") ? text.substring(index + 2) : text;
	}

	private ProxyState readState(String[] names) {
		ProxyState state = new ProxyState();
		String body = adminGet("/api/status");
		if (body == null) {
			return state;
		}
		try {
			JSONObject json = new JSONObject(body);
			for (String type : new String[] { "udp", "tcp" }) {
				JSONArray proxies = json.optJSONArray(type);
				if (proxies == null) {
					continue;
				}
				for (int i = 0; i < proxies.length(); i++) {
					JSONObject proxy = proxies.optJSONObject(i);
					if (proxy == null) {
						continue;
					}
					String name = proxy.optString("name", "");
					boolean ours = name.equals(names[0]) || name.equals(names[1]);
					if (!ours) {
						continue;
					}
					String status = proxy.optString("status", "");
					if ("running".equals(status)) {
						state.running++;
					} else if ("start error".equals(status) || "check failed".equals(status) || "closed".equals(status)) {
						String err = proxy.optString("err", "");
						state.error = status + ": " + err;
					}
				}
			}
		} catch (Exception ignored) {
		}
		return state;
	}

	/** frpc 管理接口只监听 127.0.0.1；用原始 Socket 读，避开应用的明文 HTTP 策略。 */
	private String adminGet(String path) {
		int port;
		String auth;
		synchronized (this) {
			port = adminPort;
			auth = adminAuth;
		}
		if (port <= 0) {
			return null;
		}
		try (Socket socket = new Socket()) {
			socket.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 1000);
			socket.setSoTimeout(2000);
			String request = "GET " + path + " HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Basic " + auth + "\r\nConnection: close\r\n\r\n";
			socket.getOutputStream().write(request.getBytes(StandardCharsets.US_ASCII));
			byte[] data = readAll(socket.getInputStream());
			String response = new String(data, StandardCharsets.UTF_8);
			int split = response.indexOf("\r\n\r\n");
			if (!response.startsWith("HTTP/1.") || !response.substring(0, Math.min(response.length(), 16)).contains(" 200") || split < 0) {
				return null;
			}
			return response.substring(split + 4);
		} catch (IOException exception) {
			return null;
		}
	}

	private static byte[] readAll(InputStream in) throws IOException {
		java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
		byte[] buffer = new byte[4096];
		int read;
		while ((read = in.read(buffer)) > 0 && out.size() < 256 * 1024) {
			out.write(buffer, 0, read);
		}
		return out.toByteArray();
	}

	private static int freeLoopbackPort() throws IOException {
		try (ServerSocket socket = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
			return socket.getLocalPort();
		}
	}

	private static String randomToken() {
		byte[] bytes = new byte[18];
		new SecureRandom().nextBytes(bytes);
		StringBuilder out = new StringBuilder();
		for (byte b : bytes) {
			out.append(String.format(java.util.Locale.ROOT, "%02x", b & 0xff));
		}
		return out.toString();
	}

	static boolean isAlive(Process process) {
		try {
			process.exitValue();
			return false;
		} catch (IllegalThreadStateException running) {
			return true;
		}
	}

	/** Basic 认证用的 Base64（java.util.Base64 需要 API 26，android.util.Base64 又不能在 JVM 单测里用）。 */
	static String base64(byte[] data) {
		final String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		StringBuilder out = new StringBuilder();
		for (int i = 0; i < data.length; i += 3) {
			int b0 = data[i] & 0xff;
			int b1 = i + 1 < data.length ? data[i + 1] & 0xff : 0;
			int b2 = i + 2 < data.length ? data[i + 2] & 0xff : 0;
			out.append(alphabet.charAt(b0 >> 2));
			out.append(alphabet.charAt(((b0 & 3) << 4) | (b1 >> 4)));
			out.append(i + 1 < data.length ? alphabet.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=');
			out.append(i + 2 < data.length ? alphabet.charAt(b2 & 63) : '=');
		}
		return out.toString();
	}

	private static final class ProxyState {
		int running;
		String error;
	}
}
