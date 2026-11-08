'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const yauzl = require('yauzl');
const logfiles = require('../src/main/logfiles');
const crash = require('../src/main/crash');
const { redact } = require('../src/main/logger');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-logs-test-'));
}

function write(file, text, mtimeMs) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
	if (mtimeMs) {
		fs.utimesSync(file, mtimeMs / 1000, mtimeMs / 1000);
	}
}

function zipEntries(file) {
	return new Promise((resolve, reject) => {
		yauzl.open(file, { lazyEntries: true }, (error, zip) => {
			if (error) return reject(error);
			const out = {};
			zip.on('entry', entry => {
				zip.openReadStream(entry, (streamError, stream) => {
					if (streamError) return reject(streamError);
					const chunks = [];
					stream.on('data', chunk => chunks.push(chunk));
					stream.on('end', () => {
						out[entry.fileName] = Buffer.concat(chunks).toString('utf8');
						zip.readEntry();
					});
				});
			});
			zip.on('end', () => resolve(out));
			zip.readEntry();
		});
	});
}

test('lists launcher, game, online, frp and crash logs by kind, newest first', () => {
	const dataDir = tempDir();
	const saveRoot = tempDir();
	write(path.join(dataDir, 'logs', 'launcher.log'), 'a', 3000);
	write(path.join(dataDir, 'logs', 'launcher.1.log'), 'b', 2000);
	write(path.join(dataDir, 'logs', 'other.txt'), 'x');
	for (let i = 0; i < 8; i++) {
		write(path.join(saveRoot, 'logs', `godot${i}.log`), 'g', 1000 + i * 1000);
	}
	write(path.join(saveRoot, 'launcher', 'online-game.log'), 'o');
	write(path.join(saveRoot, 'launcher', 'pending-action.json'), '{}');
	write(path.join(dataDir, 'frp', 'frpc.log'), 'f');
	write(path.join(dataDir, 'crash-reports', '20261109-120000-game.json'), '{}');
	const sources = logfiles.listLogSources({ dataDir, saveRoot });
	assert.deepStrictEqual(sources.map(s => s.id), [
		'launcher/launcher.log', 'launcher/launcher.1.log',
		'game/godot7.log', 'game/godot6.log', 'game/godot5.log', 'game/godot4.log', 'game/godot3.log', 'game/godot2.log',
		'online/online-game.log', 'frp/frpc.log', 'crash/20261109-120000-game.json',
	]);
	assert.strictEqual(logfiles.findSource(sources, 'game/godot7.log').path, path.join(saveRoot, 'logs', 'godot7.log'));
	assert.strictEqual(logfiles.findSource(sources, '../../etc/passwd'), null);
	assert.deepStrictEqual(logfiles.listLogSources({ dataDir: tempDir(), saveRoot: '' }), []);
});

test('classifies levels and keeps stack lines with their entry', () => {
	assert.strictEqual(logfiles.classifyLine('2026-11-09T12:00:00.000+08:00 W [online] x'), 'W');
	assert.strictEqual(logfiles.classifyLine('ERROR: Condition "p_node" is true.'), 'E');
	assert.strictEqual(logfiles.classifyLine('System.NullReferenceException: Object reference'), 'E');
	assert.strictEqual(logfiles.classifyLine('WARNING: something'), 'W');
	assert.strictEqual(logfiles.classifyLine('[DEBUG] verbose'), 'D');
	assert.strictEqual(logfiles.classifyLine('[OnlineRoom] hosting on UDP 33771'), 'I');
	const file = path.join(tempDir(), 'x.log');
	write(file, 'first\nERROR: boom\n   at Foo.Bar()\n    at Baz()\nok\n');
	const tail = logfiles.readTail(file);
	assert.deepStrictEqual(tail.rows.map(r => r.level), ['I', 'E', 'E', 'E', 'I']);
	assert.strictEqual(tail.truncated, false);
	const cut = logfiles.readTail(file, 17);
	assert.strictEqual(cut.truncated, true);
	assert.deepStrictEqual(cut.rows.map(r => r.text), ['    at Baz()', 'ok']);
});

test('exports a redacted zip with diagnostics and launcher config', async () => {
	const dataDir = tempDir();
	write(path.join(dataDir, 'logs', 'launcher.log'), 'login token=abc123 ok\n');
	write(path.join(dataDir, 'frp', 'frpc.log'), 'used secret-frp-token\n');
	const sources = logfiles.listLogSources({ dataDir, saveRoot: '' });
	const zipPath = path.join(dataDir, logfiles.exportName(new Date(2026, 10, 9, 8, 7, 6)));
	assert.ok(zipPath.endsWith('sts2-logs-windows-20261109-080706.zip'));
	const entries = await logfiles.exportLogs(zipPath, {
		sources,
		diagnostics: { platform: 'windows', launcher: { version: '0.2.0' } },
		config: { online: { nickname: '喵', playerId: '42' }, webdav: { password: 'pw', url: 'https://dav' }, frpToken: 'x' },
		redact: text => redact(text, ['secret-frp-token']),
	});
	assert.deepStrictEqual(entries.sort(), ['diagnostics.json', 'launcher-config.json', 'logs/frp/frpc.log', 'logs/launcher/launcher.log']);
	const files = await zipEntries(zipPath);
	assert.strictEqual(files['logs/launcher/launcher.log'], 'login token=*** ok\n');
	assert.strictEqual(files['logs/frp/frpc.log'], 'used ***\n');
	assert.deepStrictEqual(JSON.parse(files['launcher-config.json']), { online: { nickname: '喵', playerId: '42' }, webdav: { password: '***', url: 'https://dav' }, frpToken: '***' });
	assert.strictEqual(JSON.parse(files['diagnostics.json']).platform, 'windows');
	assert.ok(!fs.existsSync(`${zipPath}.part`));
});

test('records abnormal game exits and leftover launcher sessions once', () => {
	const dataDir = tempDir();
	assert.deepStrictEqual(crash.checkPreviousRun(dataDir).reports, []);
	crash.startSession(dataDir, { version: '1' });
	crash.writeLaunchMarker(dataDir, { pid: 999999, version: 'v0.111.0', mods: ['STS2CottageOnline@0.1.0'] });
	// 启动器在游戏运行时崩溃：会话和游戏标记都残留，游戏进程已不在。
	const result = crash.checkPreviousRun(dataDir, { alive: () => false });
	assert.deepStrictEqual(result.reports.map(r => r.kind).sort(), ['game', 'launcher']);
	assert.strictEqual(result.reports.find(r => r.kind === 'game').marker.version, 'v0.111.0');
	assert.strictEqual(crash.readLaunchMarker(dataDir), null);
	const pending = crash.unacknowledgedReports(dataDir);
	assert.strictEqual(pending.length, 2);
	crash.acknowledgeReports(dataDir, pending.map(r => r.name));
	assert.deepStrictEqual(crash.unacknowledgedReports(dataDir), []);
	assert.strictEqual(crash.listCrashReports(dataDir).length, 2);

	// 游戏仍在运行（启动器中途关闭）：保留标记，不算崩溃。
	crash.endSession(dataDir);
	crash.writeLaunchMarker(dataDir, { pid: 1234 });
	const running = crash.checkPreviousRun(dataDir, { alive: () => true });
	assert.strictEqual(running.gameStillRunning.pid, 1234);
	assert.deepStrictEqual(running.reports.filter(r => r.kind === 'game'), []);
	// 启动器正常关闭时游戏还在跑，之后游戏退出：拿不到退出码，只清标记。
	crash.endSession(dataDir);
	crash.updateLaunchMarker(dataDir, { launcherClosed: true });
	const unknown = crash.checkPreviousRun(dataDir, { alive: () => false });
	assert.strictEqual(unknown.clearedUnknown.pid, 1234);
	assert.deepStrictEqual(unknown.reports, []);
	assert.strictEqual(crash.readLaunchMarker(dataDir), null);
	assert.strictEqual(crash.recordCrash(dataDir, 'game', { exitCode: 3221225477 }).exitCode, 3221225477);
});
