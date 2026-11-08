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
	const card = await online.serveCard({ name: '小鱼的房间', version: 'v0.111.0', continuing: true, port: 1, platform: 'android' });
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
	assert.deepStrictEqual(rooms[0], { slot: 0, name: '小鱼的房间', version: 'v0.111.0', continuing: true, platform: 'android', host: '127.0.0.1', port: online.FIRST_GAME_PORT });
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

test('supports v0.107.1 and v0.111.0 with one component build each', () => {
	assert.deepStrictEqual(online.SUPPORTED_VERSIONS, ['v0.107.1', 'v0.111.0']);
	assert.strictEqual(online.supportsVersion('v0.107.1'), true);
	assert.strictEqual(online.supportsVersion('v0.111.0'), true);
	assert.strictEqual(online.supportsVersion('v0.110.1'), false);
	assert.strictEqual(online.supportsVersion(''), false);
	const resources = tempDir();
	assert.strictEqual(online.componentReady(resources, 'v0.111.0'), false);
	const dir = online.componentSourceDir(resources, 'v0.111.0');
	assert.strictEqual(dir, path.join(resources, 'v0.111.0', 'STS2CottageOnline'));
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, 'STS2CottageOnline.dll'), 'dll');
	assert.strictEqual(online.componentReady(resources, 'v0.111.0'), false, 'manifest missing');
	fs.writeFileSync(path.join(dir, 'STS2CottageOnline.json'), '{}');
	assert.strictEqual(online.componentReady(resources, 'v0.111.0'), true);
	assert.strictEqual(online.componentReady(resources, 'v0.107.1'), false);
	assert.deepStrictEqual(online.bundledComponentVersions(resources), ['v0.111.0']);
});

function fakeComponent(resources, version, dll) {
	const dir = online.componentSourceDir(resources, version);
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, 'STS2CottageOnline.dll'), dll);
	fs.writeFileSync(path.join(dir, 'STS2CottageOnline.json'), JSON.stringify({ id: 'STS2CottageOnline', has_dll: true }));
}

test('installs the component build matching the game version only when it changed', () => {
	const resources = tempDir();
	const modsDir = path.join(tempDir(), 'mods');
	assert.throws(() => online.installComponent(resources, 'v0.111.0', modsDir), /online_component_missing/);
	assert.throws(() => online.installComponent(resources, 'v0.110.1', modsDir), /online_unsupported_version/);
	fakeComponent(resources, 'v0.107.1', 'dll 107');
	fakeComponent(resources, 'v0.111.0', 'dll 111');
	assert.strictEqual(online.componentInstalled(modsDir), false);
	assert.strictEqual(online.installComponent(resources, 'v0.107.1', modsDir), true);
	assert.strictEqual(online.componentInstalled(modsDir), true);
	const dll = path.join(modsDir, 'STS2CottageOnline', 'STS2CottageOnline.dll');
	assert.strictEqual(fs.readFileSync(dll, 'utf8'), 'dll 107');
	assert.strictEqual(online.installComponent(resources, 'v0.107.1', modsDir), false);
	// 切换游戏版本：换成对应构建，并清掉组件目录里旧构建残留的 pdb。
	fs.writeFileSync(path.join(modsDir, 'STS2CottageOnline', 'STS2CottageOnline.pdb'), 'old');
	fs.writeFileSync(path.join(modsDir, 'STS2CottageOnline', 'notes.txt'), 'user file');
	assert.strictEqual(online.installComponent(resources, 'v0.111.0', modsDir), true);
	assert.strictEqual(fs.readFileSync(dll, 'utf8'), 'dll 111');
	assert.deepStrictEqual(fs.readdirSync(path.join(modsDir, 'STS2CottageOnline')).sort(), ['STS2CottageOnline.dll', 'STS2CottageOnline.json', 'notes.txt']);
});

test('enables the component and disables Reforged / legacy LAN mods without deleting them', () => {
	const mods = require('../src/main/mods');
	const installed = [
		{ id: 'SlayTheSpire2.LAN.Multiplayer.Reforged', name: 'LAN Multiplayer: Reforged', enabled: true, dependencies: [] },
		{ id: 'BaseLib', name: 'BaseLib', enabled: true, dependencies: [] },
		{ id: 'STS2CottageOnline', name: '小屋联机组件', enabled: false, dependencies: [] },
	];
	const json = { mod_settings: { mods_enabled: true, mod_list: [
		{ id: 'SlayTheSpire2.LAN.Multiplayer.Reforged', source: 'mods_directory', is_enabled: true },
		{ id: 'SlayTheSpire2.LAN.Multiplayer', source: 'mods_directory', is_enabled: true },
	] } };
	const result = online.enableComponentInSettings(json, mods, installed);
	assert.deepStrictEqual(result.disabledConflicts, ['LAN Multiplayer: Reforged', 'SlayTheSpire2.LAN.Multiplayer']);
	assert.deepStrictEqual(result.disabledOthers, []);
	assert.deepStrictEqual(result.enabledOthers, ['BaseLib']);
	const state = Object.fromEntries(json.mod_settings.mod_list.map(item => [item.id, item.is_enabled]));
	assert.deepStrictEqual(state, { 'SlayTheSpire2.LAN.Multiplayer.Reforged': false, 'SlayTheSpire2.LAN.Multiplayer': false, STS2CottageOnline: true });

	// 总开关原本关闭：打开它，并关掉其他原本“启用”的 MOD，只留组件。
	const vanilla = { mod_settings: { mods_enabled: false, mod_list: [] } };
	const second = online.enableComponentInSettings(vanilla, mods, installed.filter(m => m.id === 'BaseLib'));
	assert.strictEqual(vanilla.mod_settings.mods_enabled, true);
	assert.deepStrictEqual(second.disabledOthers, ['BaseLib']);
	assert.deepStrictEqual(second.enabledOthers, []);
	assert.deepStrictEqual(vanilla.mod_settings.mod_list.map(item => [item.id, item.is_enabled]), [['BaseLib', false], ['STS2CottageOnline', true]]);
});

test('builds, writes, parses and expires v1 pending actions', () => {
	const playerId = online.newPlayerId();
	const now = Date.UTC(2026, 10, 9, 4, 0, 0);
	const host = online.buildPendingAction({ type: 'host', online: true, nickname: '喵喵零', playerId, host: 'ignored', port: 1, now });
	assert.deepStrictEqual(host, { v: 1, type: 'host', created: now / 1000, online: true, nickname: '喵喵零', playerId });
	const join = online.buildPendingAction({ type: 'join', online: true, host: ' [::1] ', port: '33774', nickname: '', playerId, now });
	assert.deepStrictEqual(join, { v: 1, type: 'join', created: now / 1000, online: true, host: '::1', port: 33774, nickname: '玩家', playerId });
	assert.throws(() => online.buildPendingAction({ type: 'join', host: '', port: 1, playerId, now }), /online_bad_address/);
	assert.throws(() => online.buildPendingAction({ type: 'join', host: 'a', port: 70000, playerId, now }), /online_bad_address/);
	assert.throws(() => online.buildPendingAction({ type: 'host', playerId: '1', now }), /invalid player id/);
	assert.throws(() => online.buildPendingAction({ type: 'spectate', playerId, now }), /unknown pending action type/);

	const saveRoot = tempDir();
	const file = online.writePendingAction(saveRoot, join);
	assert.strictEqual(file, path.join(saveRoot, 'launcher', 'pending-action.json'));
	assert.deepStrictEqual(fs.readdirSync(path.dirname(file)), ['pending-action.json']);
	const text = fs.readFileSync(file, 'utf8');
	assert.deepStrictEqual(online.parsePendingAction(text, now + 599 * 1000), { action: join });
	assert.strictEqual(online.parsePendingAction(text, now + 601 * 1000).error, 'stale');
	assert.strictEqual(online.parsePendingAction('{nope', now).error, 'parse');
	assert.strictEqual(online.parsePendingAction('[1]', now).error, 'parse');
	assert.strictEqual(online.parsePendingAction(JSON.stringify({ ...join, type: 'x' }), now).error, 'type');
	assert.strictEqual(online.parsePendingAction(JSON.stringify({ ...join, port: 0 }), now).error, 'address');
	assert.strictEqual(online.parsePendingAction(JSON.stringify({ ...join, playerId: '0' }), now).error, 'player_id');

	assert.strictEqual(online.clearPendingAction(saveRoot), text);
	assert.strictEqual(fs.existsSync(file), false);
	assert.strictEqual(online.clearPendingAction(saveRoot), null);
});

test('detects an unfinished multiplayer run', () => {
	const account = tempDir();
	assert.strictEqual(online.hasMultiplayerSave(account), false);
	assert.strictEqual(online.hasMultiplayerSave(''), false);
	// 同时启用其他 MOD 时原版写 modded/profileN/saves/current_run_mp.save。
	fs.mkdirSync(path.join(account, 'modded', 'profile2', 'saves'), { recursive: true });
	fs.writeFileSync(path.join(account, 'modded', 'profile2', 'saves', 'current_lan_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(account), false, 'Reforged files are no longer recognised');
	fs.writeFileSync(path.join(account, 'modded', 'profile2', 'saves', 'current_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(account), true);
	// 只装小屋组件时保持原版存档目录 profileN/saves/current_run_mp.save。
	const plain = tempDir();
	fs.mkdirSync(path.join(plain, 'profile1', 'saves'), { recursive: true });
	fs.writeFileSync(path.join(plain, 'profile1', 'saves', 'current_run_mp.save'), '{}');
	assert.strictEqual(online.hasMultiplayerSave(plain), true);
});

test('loads the build-time server config', () => {
	const dir = tempDir();
	const file = path.join(dir, 'online.json');
	assert.strictEqual(online.loadServerConfig(file), null);
	fs.writeFileSync(file, JSON.stringify({ server: ' example.test ', serverPort: '7001' }));
	assert.deepStrictEqual(online.loadServerConfig(file), { server: 'example.test', serverPort: 7001 });
});
