package com.godot.game;

import android.content.Context;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.Calendar;
import java.util.Locale;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Launcher log shared format (doc/architecture/cross-platform-parity.md §5.1):
 * <pre>2026-11-09T12:34:56.789+08:00 E [online] 创建房间失败 | java.io.IOException: 原文
 *     at ...</pre>
 * Written to {@code <files>/logs/launcher.log}, 2 MiB per file, launcher.1.log … launcher.4.log
 * kept (5 files). Every line is redacted (frp token, Steam tokens, WebDAV password, Nexus/AI keys)
 * before it reaches the file or logcat. Safe to call from any thread.
 */
public final class LauncherLog {
	public static final String TAG_APP = "app";
	public static final String TAG_LAUNCH = "launch";
	public static final String TAG_ONLINE = "online";
	public static final String TAG_FRP = "frp";
	public static final String TAG_MODS = "mods";
	public static final String TAG_SAVES = "saves";
	public static final String TAG_CLOUD = "cloud";
	public static final String TAG_WORKSHOP = "workshop";
	public static final String TAG_NEXUS = "nexus";
	public static final String TAG_UPDATE = "update";
	public static final String TAG_UI = "ui";

	static final String FILE_NAME = "launcher.log";
	static final long MAX_BYTES = 2L * 1024L * 1024L;
	static final int KEEP_FILES = 5;
	private static final String LOGCAT_TAG = "Sts2Launcher";
	private static final String MASK = "***";
	private static final Object LOCK = new Object();
	private static final Set<String> SECRETS = ConcurrentHashMap.newKeySet();
	private static final Pattern KEY_VALUE = Pattern.compile(
		"(?i)(\\b(?:auth\\.token|token|refresh_?token|access_?token|password|passwd|pwd|api[_-]?key|apikey|secret|authorization)\\b[\"']?\\s*[:=]\\s*[\"']?)([^\"'\\s,;&}\\]]+)");
	private static final Pattern BEARER = Pattern.compile("(?i)\\b(Bearer|Basic)\\s+[A-Za-z0-9._~+/=-]+");
	private static final Pattern JWT = Pattern.compile("\\beyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}");
	private static final Pattern OPENAI_KEY = Pattern.compile("\\bsk-[A-Za-z0-9_-]{8,}");
	private static final Pattern URL_CREDENTIALS = Pattern.compile("(?i)(\\b[a-z][a-z0-9+.-]*://)[^/\\s:@]+:[^/\\s@]+@");

	private static volatile File logFile;

	private LauncherLog() {
	}

	public static void init(Context context) {
		logFile = new File(new File(context.getFilesDir(), "logs"), FILE_NAME);
	}

	static void initForTest(File file) {
		logFile = file;
	}

	public static File currentFile(Context context) {
		File file = logFile;
		return file != null ? file : new File(new File(context.getFilesDir(), "logs"), FILE_NAME);
	}

	/** Exact secret values (frp token, WebDAV password, API keys) are masked wherever they appear. */
	public static void registerSecret(String value) {
		if (value != null && value.trim().length() >= 4) {
			SECRETS.add(value.trim());
		}
	}

	public static void d(String tag, String message) {
		write('D', tag, message, null);
	}

	public static void i(String tag, String message) {
		write('I', tag, message, null);
	}

	public static void w(String tag, String message) {
		write('W', tag, message, null);
	}

	public static void w(String tag, String message, Throwable error) {
		write('W', tag, message, error);
	}

	public static void e(String tag, String message) {
		write('E', tag, message, null);
	}

	public static void e(String tag, String message, Throwable error) {
		write('E', tag, message, error);
	}

	public static void write(char level, String tag, String message, Throwable error) {
		String line = redact(formatLine(System.currentTimeMillis(), TimeZone.getDefault(), level, tag, message, error));
		try {
			android.util.Log.println(priority(level), LOGCAT_TAG, line.trim());
		} catch (RuntimeException ignored) {
			// Local JVM unit tests have no logcat; the file below is the record that matters.
		}
		File file = logFile;
		if (file == null) {
			return;
		}
		synchronized (LOCK) {
			try {
				File parent = file.getParentFile();
				if (parent != null && !parent.isDirectory() && !parent.mkdirs() && !parent.isDirectory()) {
					return;
				}
				rotateIfNeeded(file, line.getBytes(StandardCharsets.UTF_8).length);
				try (Writer writer = new OutputStreamWriter(new FileOutputStream(file, true), StandardCharsets.UTF_8)) {
					writer.write(line);
				}
			} catch (Exception writeError) {
				try {
					android.util.Log.w(LOGCAT_TAG, "launcher.log write failed: " + writeError);
				} catch (RuntimeException ignored) {
					// No logcat in local unit tests.
				}
			}
		}
	}

	static String formatLine(long epochMillis, TimeZone zone, char level, String tag, String message, Throwable error) {
		StringBuilder builder = new StringBuilder(128);
		appendTimestamp(builder, epochMillis, zone);
		builder.append(' ').append(level).append(" [").append(tag == null || tag.isEmpty() ? TAG_APP : tag).append("] ");
		builder.append(oneLine(message));
		if (error != null) {
			builder.append(" | ").append(error.getClass().getName()).append(": ").append(oneLine(error.getMessage()));
			StringWriter stack = new StringWriter();
			error.printStackTrace(new PrintWriter(stack));
			String[] lines = stack.toString().split("\n");
			// The first printStackTrace line repeats "Type: message", already on the head line.
			for (int i = 1; i < lines.length; i++) {
				String frame = lines[i].trim();
				if (!frame.isEmpty()) {
					builder.append('\n').append("    ").append(frame);
				}
			}
		}
		return builder.append('\n').toString();
	}

	public static String redact(String text) {
		if (text == null || text.isEmpty()) {
			return text;
		}
		String result = text;
		for (String secret : SECRETS) {
			result = result.replace(secret, MASK);
		}
		result = URL_CREDENTIALS.matcher(result).replaceAll("$1" + MASK + "@");
		result = BEARER.matcher(result).replaceAll("$1 " + MASK);
		result = JWT.matcher(result).replaceAll(MASK);
		result = OPENAI_KEY.matcher(result).replaceAll("sk-" + MASK);
		Matcher matcher = KEY_VALUE.matcher(result);
		StringBuffer out = new StringBuffer(result.length());
		while (matcher.find()) {
			String value = matcher.group(2);
			String replacement = MASK.equals(value) ? matcher.group(0) : matcher.group(1) + MASK;
			matcher.appendReplacement(out, Matcher.quoteReplacement(replacement));
		}
		matcher.appendTail(out);
		return out.toString();
	}

	private static void rotateIfNeeded(File file, int incomingBytes) {
		if (!file.isFile() || file.length() + incomingBytes <= MAX_BYTES) {
			return;
		}
		File directory = file.getParentFile();
		String base = file.getName().endsWith(".log") ? file.getName().substring(0, file.getName().length() - 4) : file.getName();
		File oldest = new File(directory, base + "." + (KEEP_FILES - 1) + ".log");
		if (oldest.exists() && !oldest.delete()) {
			return;
		}
		for (int index = KEEP_FILES - 2; index >= 1; index--) {
			File from = new File(directory, base + "." + index + ".log");
			if (from.exists() && !from.renameTo(new File(directory, base + "." + (index + 1) + ".log"))) {
				return;
			}
		}
		file.renameTo(new File(directory, base + ".1.log"));
	}

	private static void appendTimestamp(StringBuilder builder, long epochMillis, TimeZone zone) {
		Calendar calendar = Calendar.getInstance(zone, Locale.ROOT);
		calendar.setTimeInMillis(epochMillis);
		builder.append(String.format(Locale.ROOT, "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
			calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH) + 1, calendar.get(Calendar.DAY_OF_MONTH),
			calendar.get(Calendar.HOUR_OF_DAY), calendar.get(Calendar.MINUTE), calendar.get(Calendar.SECOND), calendar.get(Calendar.MILLISECOND)));
		int offsetMinutes = zone.getOffset(epochMillis) / 60000;
		char sign = offsetMinutes < 0 ? '-' : '+';
		offsetMinutes = Math.abs(offsetMinutes);
		builder.append(String.format(Locale.ROOT, "%c%02d:%02d", sign, offsetMinutes / 60, offsetMinutes % 60));
	}

	private static String oneLine(String text) {
		return text == null ? "" : text.replace('\r', ' ').replace('\n', ' ');
	}

	private static int priority(char level) {
		switch (level) {
			case 'D':
				return android.util.Log.DEBUG;
			case 'W':
				return android.util.Log.WARN;
			case 'E':
				return android.util.Log.ERROR;
			default:
				return android.util.Log.INFO;
		}
	}
}
