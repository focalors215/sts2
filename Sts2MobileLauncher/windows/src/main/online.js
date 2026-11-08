'use strict';

/*
 * 联机小屋：与 Android OnlineRoomService / iPad STS2RoomService 同一套在线房间（规范
 * doc/architecture/cross-platform-parity.md §3）。中心 frp 服务器上 SLOT_COUNT 个槽位，槽位 i 把
 * 房主本机 UDP 33771 映射到服务器 UDP FIRST_GAME_PORT + i，并把一张 JSON 房间卡发布在服务器
 * TCP FIRST_CARD_PORT + i；其他玩家探测这些 TCP 端口列出房间，直接连服务器的 UDP 端口加入。
 *
 * 游戏内联机由启动器自带的「小屋联机组件」STS2CottageOnline（windows/online-mod/，按游戏版本
 * 分别构建）实现：启动器按当前游戏版本把对应构建装到 <游戏目录>/mods/STS2CottageOnline/、在
 * settings.save 启用它并禁用 Reforged / 旧 LAN MOD，再写一次性指令 user://launcher/pending-action.json；
 * 游戏到主菜单后组件读取指令，用游戏自带 ENet 自动开房或加入（与 Android / iPad 同一协议）。
 */
const fs = require('fs');
const path = require('path');
const net = require('net');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { log } = require('./logger');

const LOCAL_GAME_PORT = 33771; // 游戏自带 ENet 开房端口，各端相同
const FIRST_GAME_PORT = 33771; // 服务器 UDP，frps allowPorts
const FIRST_CARD_PORT = 34771; // 服务器 TCP，frps allowPorts
const SLOT_COUNT = 20;
const SCAN_TIMEOUT_MS = 2500;
const START_TIMEOUT_MS = 20000;
const MAX_CARD_BYTES = 8192;
const COTTAGE_MOD_ID = 'STS2CottageOnline';
const COTTAGE_MOD_FILES = [`${COTTAGE_MOD_ID}.json`, `${COTTAGE_MOD_ID}.dll`];
// 组件按这些游戏版本的原版程序集分别构建（tools/windows/build-online-mod.sh）。
const SUPPORTED_VERSIONS = ['v0.107.1', 'v0.111.0'];
// 与小屋联机组件冲突的第三方 / 旧 LAN MOD：安装组件时在 settings.save 里禁用（不删文件）。
const CONFLICTING_MOD_IDS = ['SlayTheSpire2.LAN.Multiplayer.Reforged', 'SlayTheSpire2.LAN.Multiplayer'];
const PENDING_ACTION_VERSION = 1;
const PENDING_ACTION_MAX_AGE_SECONDS = 600;

function supportsVersion(version) {
	return SUPPORTED_VERSIONS.includes(version);
}

/** 随启动器打包的组件构建：resources/online-mod/<游戏版本>/STS2CottageOnline/。 */
function componentSourceDir(resourcesDir, version) {
	return path.join(resourcesDir, String(version || ''), COTTAGE_MOD_ID);
}

function hasFiles(dir, names) {
	return !!dir && names.every(name => fs.existsSync(path.join(dir, name)));
}

/** 这个游戏版本的组件构建是否随启动器打包了。 */
function componentReady(resourcesDir, version) {
	return supportsVersion(version) && hasFiles(componentSourceDir(resourcesDir, version), COTTAGE_MOD_FILES);
}

/** 打包了哪些版本的组件（界面提示用）。 */
function bundledComponentVersions(resourcesDir) {
	return SUPPORTED_VERSIONS.filter(version => componentReady(resourcesDir, version));
}

/** 游戏目录里是否已装好组件。 */
function componentInstalled(modsDir) {
	return !!modsDir && hasFiles(path.join(modsDir, COTTAGE_MOD_ID), COTTAGE_MOD_FILES);
}

/** 构建时由 scripts/prepare-assets.js 写入公开的 FRP 地址与端口；令牌不入包。 */
function loadServerConfig(file) {
	try {
		const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
		const port = Number.parseInt(raw.serverPort, 10);
		if (typeof raw.server === 'string' && raw.server.trim()) {
			return { server: raw.server.trim(), serverPort: Number.isFinite(port) ? port : 7000 };
		}
	} catch (error) {
		if (error.code !== 'ENOENT') {
			log().w('online', `读取联机服务器配置失败: ${file}`, error);
		}
	}
	return null;
}

function normalizeNickname(value, fallback) {
	let text = String(value || '').trim();
	if (!text) {
		text = fallback;
	}
	return [...text].slice(0, 16).join('');
}

/** 非零、不是 ENet 房主 1 的随机 63 位联机身份（十进制字符串，同 Android lan_player_id）。 */
function newPlayerId() {
	let id = 0n;
	while (id <= 1n) {
		id = crypto.randomBytes(8).readBigUInt64BE() & 0x7fffffffffffffffn;
	}
	return id.toString();
}

function isValidPlayerId(value) {
	return typeof value === 'string' && /^\d{1,20}$/.test(value) && BigInt(value) > 1n && BigInt(value) <= 0xffffffffffffffffn;
}

/** 探测一个槽位的房间卡：连上后读到对端关闭，内容须是 JSON 对象。 */
function probeCard(host, port, timeoutMs) {
	return new Promise(resolve => {
		const chunks = [];
		let size = 0;
		let done = false;
		const socket = net.connect({ host, port });
		const finish = value => {
			if (!done) {
				done = true;
				socket.destroy();
				resolve(value);
			}
		};
		socket.setTimeout(timeoutMs, () => finish(parse()));
		socket.on('data', chunk => {
			size += chunk.length;
			chunks.push(chunk);
			if (size >= MAX_CARD_BYTES) {
				finish(parse());
			}
		});
		socket.on('end', () => finish(parse()));
		socket.on('error', error => {
			// 空槽位没有监听，连接被拒绝是常态。
			if (error.code !== 'ECONNREFUSED') {
				log().d('online', `探测房间卡 ${host}:${port} 失败`, error);
			}
			finish(null);
		});
		function parse() {
			try {
				const info = JSON.parse(Buffer.concat(chunks).subarray(0, MAX_CARD_BYTES).toString('utf8'));
				return info && typeof info === 'object' && !Array.isArray(info) ? info : null;
			} catch (error) {
				if (chunks.length) {
					log().d('online', `房间卡 ${host}:${port} 不是 JSON`, error);
				}
				return null;
			}
		}
	});
}

async function scanRooms(server, options = {}) {
	const firstPort = options.firstCardPort || FIRST_CARD_PORT;
	const count = options.slotCount || SLOT_COUNT;
	const timeout = options.timeoutMs || SCAN_TIMEOUT_MS;
	const found = await Promise.all(Array.from({ length: count }, (_, slot) => probeCard(server, firstPort + slot, timeout)));
	const rooms = [];
	found.forEach((info, slot) => {
		if (!info) {
			return;
		}
		// 可加入的端口由槽位推出，不信任卡片里的 port。
		rooms.push({
			slot,
			name: typeof info.name === 'string' && info.name ? info.name.slice(0, 64) : '',
			version: typeof info.version === 'string' && info.version ? info.version.slice(0, 32) : 'unknown',
			continuing: info.continuing === true,
			platform: ['android', 'windows', 'ios'].includes(info.platform) ? info.platform : '',
			host: server,
			port: FIRST_GAME_PORT + slot,
		});
	});
	return rooms;
}

/** 在 127.0.0.1 随机端口上给每个 TCP 连接写一次房间卡（同 frp bridge 的 Sts2RoomServe）。 */
function serveCard(card) {
	const data = Buffer.from(JSON.stringify(card), 'utf8');
	return new Promise((resolve, reject) => {
		const server = net.createServer(socket => {
			socket.setTimeout(5000, () => socket.destroy());
			socket.on('error', error => log().d('online', '房间卡连接出错', error));
			socket.end(data);
		});
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server));
	});
}

// TOML 基本字符串：转义反斜杠、引号和控制字符。
function toml(value) {
	return `"${String(value).replace(/[\\"\u0000-\u001f\u007f]/g, c => (c === '\\' || c === '"' ? `\\${c}` : `\\u${c.charCodeAt(0).toString(16).padStart(4, '0').toUpperCase()}`))}"`;
}

function frpConfig(serverConfig, logFile, proxies) {
	let text = `serverAddr = ${toml(serverConfig.server)}\n`
		+ `serverPort = ${serverConfig.serverPort}\n`
		+ 'loginFailExit = true\n'
		+ 'auth.method = "token"\n'
		+ `auth.token = ${toml(serverConfig.token)}\n`
		+ `log.to = ${toml(logFile)}\n`
		+ 'log.level = "info"\nlog.maxDays = 1\n';
	for (const proxy of proxies) {
		text += `\n[[proxies]]\nname = ${toml(proxy.name)}\ntype = ${toml(proxy.type)}\nlocalIP = "127.0.0.1"\nlocalPort = ${proxy.localPort}\nremotePort = ${proxy.remotePort}\n`;
	}
	return text;
}

// frp 常见失败前加一句中文提示，保留 frp 原文便于排查（同 Android describe）。
const HINTS = [
	['token', '令牌（token）与服务器不一致。'],
	['port not allowed', '服务器不允许该远程端口（检查 frps 的 allowPorts）。'],
	['already', '远程端口或映射名已被占用：可能有其他房主在用，或上次连接未释放（约 1 分钟后重试）。'],
	['port unavailable', '服务器上该远程端口已被占用。'],
	['connection refused', '连不上 frp 服务器：检查地址、端口，以及服务器防火墙/安全组。'],
	['eof', '连接被服务器或网络中断：检查端口是否为 frps 端口、是否被代理软件拦截。'],
	['timeout', '连接 frp 服务器超时：检查网络和服务器防火墙/安全组。'],
];

function describeFrpError(message) {
	const lower = String(message).toLowerCase();
	const hint = HINTS.find(([key]) => lower.includes(key));
	return hint ? `${hint[1]}\n(${message})` : String(message);
}

function isTakenError(message) {
	return String(message).toLowerCase().includes('already') || String(message).includes('占用');
}

/** 一个房主会话：房间卡服务 + frp 助手进程（stdin 关闭即退出，启动器退出时隧道随之关闭）。 */
class RoomHost {
	constructor({ helperPath, workDir, serverConfig, onStateChange }) {
		this.helperPath = helperPath;
		this.workDir = workDir;
		this.serverConfig = serverConfig;
		this.onStateChange = onStateChange || (() => {});
		this.cardServer = null;
		this.child = null;
		this.room = null;
		this.state = 'idle'; // idle / starting / running / reconnecting
	}

	setState(state) {
		this.state = state;
		this.onStateChange(state);
	}

	/** 抢一个空槽位开房；返回 { slot, port, name }。 */
	async create({ nickname, version, continuing }) {
		if (!fs.existsSync(this.helperPath)) {
			throw new Error('online_component_missing');
		}
		this.stop();
		this.setState('starting');
		const taken = new Set((await scanRooms(this.serverConfig.server)).map(room => room.slot));
		let error = '服务器房间已满，请稍后再试。';
		let tried = 0;
		for (let slot = 0; slot < SLOT_COUNT && tried < 3; slot++) {
			if (taken.has(slot)) {
				continue;
			}
			tried++;
			// 扫描和注册之间槽位可能被别人占走，失败就试下一个。
			try {
				log().i('frp', `尝试槽位 ${slot}（UDP ${FIRST_GAME_PORT + slot} / TCP ${FIRST_CARD_PORT + slot}）`);
				await this.start(slot, nickname, version, continuing);
				this.room = { slot, port: FIRST_GAME_PORT + slot, name: `${nickname}的房间` };
				this.setState('running');
				log().i('online', `房间已开启: 槽位 ${slot}，服务器 ${this.serverConfig.server}:${FIRST_GAME_PORT + slot}`);
				return this.room;
			} catch (startError) {
				error = startError.message;
				log().w('frp', `槽位 ${slot} 开房失败`, startError);
				this.stopProcesses();
				if (!isTakenError(error)) {
					break;
				}
			}
		}
		this.setState('idle');
		log().e('online', `创建在线房间失败: ${error}`);
		throw new Error(error);
	}

	async start(slot, nickname, version, continuing) {
		const card = {
			v: 1,
			name: `${nickname}的房间`,
			host: nickname,
			version,
			continuing,
			created: Math.floor(Date.now() / 1000),
			slot,
			port: FIRST_GAME_PORT + slot,
			platform: 'windows',
		};
		this.cardServer = await serveCard(card);
		const gameProxy = `sts2-room-${slot}-game`;
		const cardProxy = `sts2-room-${slot}-card`;
		fs.mkdirSync(this.workDir, { recursive: true });
		const configFile = path.join(this.workDir, 'frpc.toml');
		fs.writeFileSync(configFile, frpConfig(this.serverConfig, path.join(this.workDir, 'frpc.log'), [
			{ name: gameProxy, type: 'udp', localPort: LOCAL_GAME_PORT, remotePort: FIRST_GAME_PORT + slot },
			{ name: cardProxy, type: 'tcp', localPort: this.cardServer.address().port, remotePort: FIRST_CARD_PORT + slot },
		]), 'utf8');
		await new Promise((resolve, reject) => {
			const child = spawn(this.helperPath, ['-c', configFile, '-wait', `${gameProxy},${cardProxy}`], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
			this.child = child;
			let settled = false;
			let buffer = '';
			const settle = (fn, value) => {
				if (!settled) {
					settled = true;
					clearTimeout(timer);
					fn(value);
				}
			};
			const timer = setTimeout(() => settle(reject, new Error(describeFrpError('连接服务器超时'))), START_TIMEOUT_MS);
			child.stdin.on('error', error => log().d('frp', 'frp 助手 stdin 已关闭', error));
			child.once('error', error => {
				log().e('frp', `无法启动 frp 助手: ${this.helperPath}`, error);
				settle(reject, error);
			});
			child.stdout.on('data', chunk => {
				buffer += chunk.toString('utf8');
				let index;
				while ((index = buffer.indexOf('\n')) >= 0) {
					const line = buffer.slice(0, index).trim();
					buffer = buffer.slice(index + 1);
					let event;
					try {
						event = JSON.parse(line);
					} catch (error) {
						log().d('frp', `frp 助手输出: ${line}`);
						continue;
					}
					log().i('frp', `frp 状态: ${event.state}${event.error ? ` (${event.error})` : ''}`);
					if (event.state === 'running') {
						if (settled && this.state === 'reconnecting') {
							this.setState('running');
						}
						settle(resolve);
					} else if (event.state === 'starting' && settled && this.child === child) {
						this.setState('reconnecting');
					} else if (event.state === 'error') {
						settle(reject, new Error(describeFrpError(event.error || 'frp error')));
					}
				}
			});
			child.once('exit', code => {
				log().i('frp', `frp 助手退出，代码 ${code}`);
				settle(reject, new Error(describeFrpError(`frp 已退出（${code}）`)));
				if (this.child === child && (this.state === 'running' || this.state === 'reconnecting')) {
					// 运行中隧道断开（登录失效、被服务器踢下线等）：房间已不在列表里。
					this.child = null;
					this.closeCard();
					this.room = null;
					this.setState('idle');
				}
			});
		});
	}

	closeCard() {
		if (this.cardServer) {
			this.cardServer.close();
			this.cardServer = null;
		}
	}

	stopProcesses() {
		const child = this.child;
		this.child = null;
		if (child) {
			try {
				child.stdin.end();
			} catch (error) {
				log().d('frp', '关闭 frp 助手 stdin 失败（可能已退出）', error);
			}
			setTimeout(() => {
				if (child.exitCode === null) {
					child.kill();
				}
			}, 2000).unref();
		}
		this.closeCard();
	}

	stop() {
		const wasActive = this.state !== 'idle';
		this.stopProcesses();
		this.room = null;
		if (wasActive) {
			this.setState('idle');
		}
	}
}

/** 本机局域网 IPv4，供“局域网直连”告诉朋友填写。 */
function localIpv4Addresses() {
	const out = [];
	for (const [name, list] of Object.entries(os.networkInterfaces())) {
		for (const item of list || []) {
			if ((item.family === 'IPv4' || item.family === 4) && !item.internal && !item.address.startsWith('169.254.')) {
				out.push({ name, address: item.address });
			}
		}
	}
	return out;
}

/**
 * 当前账号是否有未完成的多人存档，用于房间卡“继续存档”。原版写 current_run_mp.save：
 * 只装小屋联机组件时在 <账号>/profileN/saves/，同时启用了其他 MOD 时在 <账号>/modded/profileN/saves/。
 */
function hasMultiplayerSave(accountDir) {
	if (!accountDir) {
		return false;
	}
	const names = ['current_run_mp.save', 'current_run_mp.save.backup'];
	const search = (dir, depth) => {
		let entries;
		try {
			entries = fs.readdirSync(dir, { withFileTypes: true });
		} catch (error) {
			return false;
		}
		if (entries.some(entry => entry.isDirectory() && entry.name.startsWith('profile')
			&& names.some(name => fs.existsSync(path.join(dir, entry.name, 'saves', name))))) {
			return true;
		}
		if (depth >= 2) {
			return false;
		}
		return entries.some(entry => entry.isDirectory() && !entry.name.startsWith('.')
			&& search(path.join(dir, entry.name), depth + 1));
	};
	return search(accountDir, 0);
}

/**
 * 把这个游戏版本的组件构建复制到 <modsDir>/STS2CottageOnline/（内容相同则不动），并删掉组件
 * 目录里不属于这次构建的旧文件（只限组件自己的目录）。返回是否有变化。
 */
function installComponent(resourcesDir, version, modsDir) {
	const sourceDir = componentSourceDir(resourcesDir, version);
	if (!componentReady(resourcesDir, version)) {
		throw new Error(supportsVersion(version) ? 'online_component_missing' : 'online_unsupported_version');
	}
	const target = path.join(modsDir, COTTAGE_MOD_ID);
	fs.mkdirSync(target, { recursive: true });
	let changed = false;
	const incomingNames = new Set();
	for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
		if (!entry.isFile()) {
			continue;
		}
		incomingNames.add(entry.name.toLowerCase());
		const from = path.join(sourceDir, entry.name);
		const to = path.join(target, entry.name);
		const incoming = fs.readFileSync(from);
		if (fs.existsSync(to) && fs.readFileSync(to).equals(incoming)) {
			continue;
		}
		const temp = `${to}.${process.pid}.tmp`;
		fs.writeFileSync(temp, incoming);
		fs.renameSync(temp, to);
		changed = true;
	}
	for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
		if (entry.isFile() && !incomingNames.has(entry.name.toLowerCase()) && /\.(dll|json|pdb|pck)$/i.test(entry.name)) {
			fs.rmSync(path.join(target, entry.name), { force: true });
			changed = true;
		}
	}
	return changed;
}

/** pending-action.json 的位置：游戏 user://（Windows 为存档根目录）下的 launcher/。 */
function pendingActionPath(saveRoot) {
	return path.join(saveRoot, 'launcher', 'pending-action.json');
}

/** 组一条 v1 指令（规范 §3.3）。type=host 时 host/port 不写。 */
function buildPendingAction({ type, online: isOnline, host, port, nickname, playerId, now = Date.now() }) {
	if (type !== 'host' && type !== 'join') {
		throw new Error(`unknown pending action type: ${type}`);
	}
	if (!isValidPlayerId(playerId)) {
		throw new Error('invalid player id');
	}
	const action = { v: PENDING_ACTION_VERSION, type, created: Math.floor(now / 1000), online: !!isOnline };
	if (type === 'join') {
		const cleanHost = String(host || '').trim().replace(/^\[(.*)\]$/, '$1');
		const cleanPort = Number.parseInt(port, 10);
		if (!cleanHost || !(cleanPort > 0 && cleanPort <= 65535)) {
			throw new Error('online_bad_address');
		}
		action.host = cleanHost;
		action.port = cleanPort;
	}
	action.nickname = normalizeNickname(nickname, '玩家');
	action.playerId = playerId;
	return action;
}

/** 原子写入指令文件。 */
function writePendingAction(saveRoot, action) {
	const file = pendingActionPath(saveRoot);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const temp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(temp, JSON.stringify(action), 'utf8');
	fs.renameSync(temp, file);
	return file;
}

/**
 * 读取并校验一条指令（与游戏内组件的判定相同）：返回 { action } 或 { error }。
 * 过期（created 距今超过 600 s）、解析失败、未知 type、地址非法都算错误。
 */
function parsePendingAction(text, now = Date.now()) {
	let action;
	try {
		action = JSON.parse(text);
	} catch (error) {
		return { error: 'parse' };
	}
	if (!action || typeof action !== 'object' || Array.isArray(action)) {
		return { error: 'parse' };
	}
	const created = Number(action.created) || 0;
	if (Math.abs(Math.floor(now / 1000) - created) > PENDING_ACTION_MAX_AGE_SECONDS) {
		return { error: 'stale', action };
	}
	if (action.type !== 'host' && action.type !== 'join') {
		return { error: 'type', action };
	}
	if (action.type === 'join') {
		const port = Number(action.port);
		if (typeof action.host !== 'string' || !action.host.trim() || !Number.isInteger(port) || port <= 0 || port > 65535) {
			return { error: 'address', action };
		}
		if (!isValidPlayerId(String(action.playerId || ''))) {
			return { error: 'player_id', action };
		}
	}
	return { action };
}

/** 启动器打开时清掉上次遗留的指令（同 Android GameSettingsActivity），返回被清掉的内容。 */
function clearPendingAction(saveRoot) {
	const file = pendingActionPath(saveRoot);
	if (!fs.existsSync(file)) {
		return null;
	}
	let text = '';
	try {
		text = fs.readFileSync(file, 'utf8');
	} catch (error) {
		log().w('online', `读取遗留联机指令失败: ${file}`, error);
	}
	fs.rmSync(file, { force: true });
	return text;
}

/**
 * 在 settings.save（已解析的 JSON）里启用组件、禁用冲突 MOD。mods 为 mods.js 的 MOD 视图列表。
 * MOD 总开关原本关着时打开它，并把其他已启用的 MOD 设为禁用，避免玩法 MOD 随之加载导致双方不同步。
 * 返回 { disabledConflicts, disabledOthers, enabledOthers }（名称列表）。
 */
function enableComponentInSettings(json, modsApi, installedMods) {
	const modSettings = modsApi.modSettingsOf(json);
	const nameOf = id => {
		const mod = installedMods.find(m => m.id === id);
		return mod ? (mod.name || mod.id) : id;
	};
	const disabledConflicts = [];
	const disabledOthers = [];
	for (const id of CONFLICTING_MOD_IDS) {
		const mod = installedMods.find(m => m.id === id);
		const listed = modSettings.mod_list.some(item => item && item.id === id && item.is_enabled !== false);
		if ((mod && mod.enabled) || listed) {
			disabledConflicts.push(nameOf(id));
		}
		if (mod || listed) {
			modsApi.setDisabled(json, id, true);
		}
	}
	if (!modSettings.mods_enabled) {
		modSettings.mods_enabled = true;
		for (const mod of installedMods) {
			if (mod.id !== COTTAGE_MOD_ID && !CONFLICTING_MOD_IDS.includes(mod.id) && mod.enabled) {
				modsApi.setDisabled(json, mod.id, true);
				disabledOthers.push(mod.name || mod.id);
			}
		}
	}
	modsApi.setDisabled(json, COTTAGE_MOD_ID, false);
	const enabledOthers = installedMods
		.filter(mod => mod.id !== COTTAGE_MOD_ID && !CONFLICTING_MOD_IDS.includes(mod.id) && mod.enabled && !disabledOthers.includes(mod.name || mod.id))
		.map(mod => mod.name || mod.id);
	return { disabledConflicts, disabledOthers, enabledOthers };
}

module.exports = {
	LOCAL_GAME_PORT,
	FIRST_GAME_PORT,
	FIRST_CARD_PORT,
	SLOT_COUNT,
	COTTAGE_MOD_ID,
	COTTAGE_MOD_FILES,
	CONFLICTING_MOD_IDS,
	SUPPORTED_VERSIONS,
	PENDING_ACTION_MAX_AGE_SECONDS,
	supportsVersion,
	componentSourceDir,
	componentReady,
	bundledComponentVersions,
	componentInstalled,
	installComponent,
	enableComponentInSettings,
	pendingActionPath,
	buildPendingAction,
	writePendingAction,
	parsePendingAction,
	clearPendingAction,
	loadServerConfig,
	normalizeNickname,
	newPlayerId,
	isValidPlayerId,
	scanRooms,
	serveCard,
	frpConfig,
	describeFrpError,
	RoomHost,
	localIpv4Addresses,
	hasMultiplayerSave,
};
