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

test('supports only the game version the bundled LAN mod was built for', () => {
	assert.deepStrictEqual(online.SUPPORTED_VERSIONS, ['v0.107.1']);
	assert.strictEqual(online.supportsVersion('v0.107.1'), true);
	assert.strictEqual(online.supportsVersion('v0.111.0'), false);
	assert.strictEqual(online.supportsVersion(''), false);
});

test('formats join addresses as IP:port, bracketing IPv6', () => {
	assert.strictEqual(online.joinAddress('1.2.3.4', 33771), '1.2.3.4:33771');
	assert.strictEqual(online.joinAddress('  example.test  ', '33772'), 'example.test:33772');
	assert.strictEqual(online.joinAddress('::1', 33771), '[::1]:33771');
	assert.strictEqual(online.joinAddress('[fe80::1]', 33771), '[fe80::1]:33771');
});

test('merges the LAN mod settings file and keeps unknown fields', () => {
	const account = tempDir();
	assert.deepStrictEqual(online.readLanSettings(account), {});
	const first = online.writeLanSettings(account, { host_port: 33771, player_name: '喵喵零' });
	assert.deepStrictEqual(first, { host_port: 33771, player_name: '喵喵零' });
	const file = online.lanSettingsPath(account);
	assert.strictEqual(file, path.join(account, 'mods', online.LAN_SETTINGS_FILE));
	const second = online.writeLanSettings(account, { ip_address: '1.2.3.4:33772', host_port: 33772 });
	assert.deepStrictEqual(second, { host_port: 33772, player_name: '喵喵零', ip_address: '1.2.3.4:33772' });
	assert.deepStrictEqual(JSON.parse(fs.readFileSync(file, 'utf8')), second);
	assert.deepStrictEqual(fs.readdirSync(path.dirname(file)), [online.LAN_SETTINGS_FILE]);
});

test('reports whether the bundled LAN mod and BaseLib are ready and installed', () => {
	const resources = tempDir();
	const modsDir = path.join(tempDir(), 'mods');
	assert.strictEqual(online.modsReady(resources), false);
	assert.strictEqual(online.modsInstalled(modsDir), false);
	for (const [id, files] of [[online.LAN_MOD_ID, online.LAN_MOD_FILES], [online.BASE_LIB_ID, online.BASE_LIB_FILES]]) {
		const dir = online.modSourceDir(resources, id);
		fs.mkdirSync(dir, { recursive: true });
		files.slice(0, id === online.BASE_LIB_ID ? -1 : undefined).forEach(name => fs.writeFileSync(path.join(dir, name), 'x'));
	}
	assert.strictEqual(online.modsReady(resources), false, 'BaseLib is missing a file');
	fs.writeFileSync(path.join(online.modSourceDir(resources, online.BASE_LIB_ID), online.BASE_LIB_FILES.at(-1)), 'x');
	assert.strictEqual(online.modsReady(resources), true);
	assert.strictEqual(online.modsInstalled(modsDir), false);
	assert.strictEqual(online.modsInstalled(''), false);
});

test('installs the LAN mod and BaseLib only when they changed', () => {
	const resources = tempDir();
	const modsDir = path.join(tempDir(), 'mods');
	assert.throws(() => online.installLanMods(resources, modsDir), /online_component_missing/);
	for (const [id, files] of [[online.LAN_MOD_ID, online.LAN_MOD_FILES], [online.BASE_LIB_ID, online.BASE_LIB_FILES]]) {
		const dir = online.modSourceDir(resources, id);
		fs.mkdirSync(dir, { recursive: true });
		files.forEach(name => fs.writeFileSync(path.join(dir, name), `${id}:${name}`));
	}
	assert.strictEqual(online.installLanMods(resources, modsDir), true);
	assert.strictEqual(online.modsInstalled(modsDir), true);
	assert.strictEqual(online.installLanMods(resources, modsDir), false);
	fs.writeFileSync(path.join(online.modSourceDir(resources, online.LAN_MOD_ID), `${online.LAN_MOD_ID}.dll`), 'dll v2');
	assert.strictEqual(online.installLanMods(resources, modsDir), true);
	assert.strictEqual(fs.readFileSync(path.join(modsDir, online.LAN_MOD_ID, `${online.LAN_MOD_ID}.dll`), 'utf8'), 'dll v2');
});

test('detects an unfinished multiplayer run', () => {
	const account = tempDir();
	assert.strictEqual(online.hasMultiplayerSave(account), false);
	assert.strictEqual(online.hasMultiplayerSave(''), false);
	// Reforged 在启用 MOD 后写 modded/profileN/saves/current_lan_run_mp.save。
	fs.mkdirSync(path.join(account, 'modded', 'profile2', 'saves'), { recursive: true });
	fs.writeFileSync(path.join(account, 'modded', 'profile2', 'saves', 'current_lan_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(account), true);
	// 旧的小屋组件写在未启用 MOD 的 profileN/saves/current_run_mp.save。
	const plain = tempDir();
	fs.mkdirSync(path.join(plain, 'profile1', 'saves'), { recursive: true });
	fs.writeFileSync(path.join(plain, 'profile1', 'saves', 'current_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(plain), true);
});

test('loads the build-time server config', () => {
	const dir = tempDir();
	const file = path.join(dir, 'online.json');
	assert.strictEqual(online.loadServerConfig(file), null);
	fs.writeFileSync(file, JSON.stringify({ server: ' example.test ', serverPort: '7001', token: 't' }));
	assert.deepStrictEqual(online.loadServerConfig(file), { server: 'example.test', serverPort: 7001, token: 't' });
});
