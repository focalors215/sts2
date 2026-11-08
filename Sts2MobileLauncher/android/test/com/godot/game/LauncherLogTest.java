package com.godot.game;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.TimeZone;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

/** doc/architecture/cross-platform-parity.md §5.1: line format, redaction and rotation. */
public class LauncherLogTest {
	@Rule public TemporaryFolder temporary = new TemporaryFolder();

	@Test public void plainLineMatchesSharedFormat() {
		long time = 1794198896789L; // 2026-11-09T04:34:56.789Z
		String line = LauncherLog.formatLine(time, TimeZone.getTimeZone("Asia/Shanghai"), 'I', "online", "读取房间\n第二行", null);
		assertEquals("2026-11-09T12:34:56.789+08:00 I [online] 读取房间 第二行\n", line);
		String utc = LauncherLog.formatLine(time, TimeZone.getTimeZone("UTC"), 'W', "frp", "x", null);
		assertTrue(utc, utc.startsWith("2026-11-09T04:34:56.789+00:00 W [frp] x"));
	}

	@Test public void exceptionLineCarriesTypeMessageAndIndentedStack() {
		IOException error = new IOException("连接被拒绝", new IllegalStateException("inner"));
		String line = LauncherLog.formatLine(0L, TimeZone.getTimeZone("UTC"), 'E', "online", "创建房间失败", error);
		String[] lines = line.split("\n");
		assertEquals("1970-01-01T00:00:00.000+00:00 E [online] 创建房间失败 | java.io.IOException: 连接被拒绝", lines[0]);
		assertTrue(lines[1], lines[1].startsWith("    at "));
		assertTrue(line, line.contains("    Caused by: java.lang.IllegalStateException: inner"));
	}

	@Test public void secretsAreMasked() {
		LauncherLog.registerSecret("frp-token-value-123");
		String redacted = LauncherLog.redact("auth.token = \"frp-token-value-123\" token=abcdef refresh_token: eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.c2lnbmF0dXJlXzEy "
			+ "Authorization: Bearer abc.def password=hunter22 \"apiKey\":\"nexus-key\" sk-proj1234567890 https://user:pass@dav.example.com/x");
		assertFalse(redacted, redacted.contains("frp-token-value-123"));
		assertFalse(redacted, redacted.contains("abcdef"));
		assertFalse(redacted, redacted.contains("eyJhbGci"));
		assertFalse(redacted, redacted.contains("abc.def"));
		assertFalse(redacted, redacted.contains("hunter22"));
		assertFalse(redacted, redacted.contains("nexus-key"));
		assertFalse(redacted, redacted.contains("proj1234567890"));
		assertFalse(redacted, redacted.contains("user:pass"));
		assertTrue(redacted, redacted.contains("https://***@dav.example.com/x"));
		assertEquals("settings key log_level=info", LauncherLog.redact("settings key log_level=info"));
	}

	@Test public void writesRedactedLinesAndRotatesKeepingFiveFiles() throws Exception {
		File directory = temporary.newFolder("logs");
		File file = new File(directory, LauncherLog.FILE_NAME);
		LauncherLog.initForTest(file);
		try {
			LauncherLog.e("online", "登录失败 password=secret-value");
			String content = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
			assertTrue(content, content.contains(" E [online] 登录失败 password=***"));

			StringBuilder big = new StringBuilder();
			while (big.length() < 300_000) {
				big.append("0123456789");
			}
			for (int i = 0; i < 60; i++) {
				LauncherLog.i("app", big.toString());
			}
			assertTrue(file.length() <= LauncherLog.MAX_BYTES);
			for (int index = 1; index < LauncherLog.KEEP_FILES; index++) {
				assertTrue("launcher." + index + ".log", new File(directory, "launcher." + index + ".log").isFile());
			}
			assertFalse(new File(directory, "launcher." + LauncherLog.KEEP_FILES + ".log").exists());
		} finally {
			LauncherLog.initForTest(null);
		}
	}
}
