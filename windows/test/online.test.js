'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const online = require('../src/main/online');
const { LauncherConfig } = require('../src/main/config');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-online-test-'));
}

function listen(server) {
	return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

test('scans room cards and derives the join port from the slot', async () => {
	// 连续三个端口：有效卡片、非 JSON、无人监听（关闭的端口）。
	const card = await online.serveCard({ name: '小鱼的房间', version: 'v0.111.0', continuing: true, port: 1 });
	const base = card.address().port;
	const junk = net.createServer(socket => socket.end('not json'));
	let junkPort;
	try {
		junkPort = await new Promise((resolve, reject) => {
			junk.once('error', reject);
			junk.listen(base + 1, '127.0.0.1', () => resolve(base + 1));
		});
	} catch (error) {
		junkPort = null;
	}
	const rooms = await online.scanRooms('127.0.0.1', { firstCardPort: base, slotCount: junkPort ? 3 : 1, timeoutMs: 1000 });
	card.close();
	junk.close();
	assert.strictEqual(rooms.length, 1);
	assert.deepStrictEqual(rooms[0], { slot: 0, name: '小鱼的房间', version: 'v0.111.0', continuing: true, host: '127.0.0.1', port: online.FIRST_GAME_PORT });
});

test('writes a TOML frp config with escaped values', () => {
	const text = online.frpConfig({ server: 'a"b', serverPort: 7000, token: 'x\\y\n' }, 'C:\\logs\\frpc.log', [
		{ name: 'sts2-room-3-game', type: 'udp', localPort: 33771, remotePort: 33774 },
	]);
	assert.match(text, /serverAddr = "a\\"b"/);
	assert.match(text, /auth\.token = "x\\\\y\\u000A"/);
	assert.match(text, /log\.to = "C:\\\\logs\\\\frpc\.log"/);
	assert.match(text, /\[\[proxies\]\]\nname = "sts2-room-3-game"\ntype = "udp"\nlocalIP = "127\.0\.0\.1"\nlocalPort = 33771\nremotePort = 33774/);
});

test('adds Chinese hints to common frp errors', () => {
	assert.match(online.describeFrpError('login to server failed: token in login doesn\'t match'), /^令牌/);
	assert.strictEqual(online.describeFrpError('something else'), 'something else');
});

test('player ids are random, non-zero and never the ENet host id', () => {
	const ids = new Set(Array.from({ length: 50 }, () => online.newPlayerId()));
	assert.strictEqual(ids.size, 50);
	for (const id of ids) {
		assert.ok(online.isValidPlayerId(id));
	}
	assert.ok(!online.isValidPlayerId('1'));
	assert.ok(!online.isValidPlayerId('0'));
	assert.ok(!online.isValidPlayerId('18446744073709551616'));
});

test('persists nickname and player id in launcher config', () => {
	const dir = tempDir();
	const config = new LauncherConfig(dir);
	const first = config.updateOnline({ nickname: '  喵喵零喵喵零喵喵零喵喵零喵喵零喵喵零  ' });
	assert.strictEqual([...first.nickname].length, 16);
	assert.strictEqual(first.lanPort, 33771);
	const again = new LauncherConfig(dir);
	assert.strictEqual(again.online.playerId, first.playerId);
	assert.strictEqual(again.updateOnline({ nickname: '' }).nickname, '玩家');
});

test('writes and clears the pending action under the game user dir', () => {
	const root = tempDir();
	online.writePendingAction(root, { type: 'join', host: '1.2.3.4', port: 33775 });
	const action = JSON.parse(fs.readFileSync(path.join(root, 'launcher', 'pending-action.json'), 'utf8'));
	assert.strictEqual(action.type, 'join');
	assert.strictEqual(action.v, 1);
	assert.ok(Math.abs(action.created - Date.now() / 1000) < 5);
	online.clearPendingAction(root);
	assert.ok(!fs.existsSync(online.pendingActionPath(root)));
});

test('installs the online component MOD only when it changed', () => {
	const source = tempDir();
	const modsDir = path.join(tempDir(), 'mods');
	assert.throws(() => online.installOnlineMod(source, modsDir), /online_component_missing/);
	fs.writeFileSync(path.join(source, 'STS2CottageOnline.dll'), 'dll');
	fs.writeFileSync(path.join(source, 'STS2CottageOnline.json'), '{"id":"STS2CottageOnline"}');
	assert.strictEqual(online.installOnlineMod(source, modsDir), true);
	assert.strictEqual(online.installOnlineMod(source, modsDir), false);
	fs.writeFileSync(path.join(source, 'STS2CottageOnline.dll'), 'dll v2');
	assert.strictEqual(online.installOnlineMod(source, modsDir), true);
	assert.strictEqual(fs.readFileSync(path.join(modsDir, 'STS2CottageOnline', 'STS2CottageOnline.dll'), 'utf8'), 'dll v2');
});

test('detects an unfinished multiplayer run', () => {
	const account = tempDir();
	assert.strictEqual(online.hasMultiplayerSave(account), false);
	fs.mkdirSync(path.join(account, 'profile2', 'saves'), { recursive: true });
	fs.writeFileSync(path.join(account, 'profile2', 'saves', 'current_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(account), true);
});

test('loads the build-time server config', () => {
	const dir = tempDir();
	const file = path.join(dir, 'online.json');
	assert.strictEqual(online.loadServerConfig(file), null);
	fs.writeFileSync(file, JSON.stringify({ server: ' example.test ', serverPort: '7001', token: 't' }));
	assert.deepStrictEqual(online.loadServerConfig(file), { server: 'example.test', serverPort: 7001, token: 't' });
});
