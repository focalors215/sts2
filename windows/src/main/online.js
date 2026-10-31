'use strict';

/*
 * 联机小屋：与 Android OnlineRoomService / iPad STS2RoomService 同一套在线房间。
 * 中心 frp 服务器上 SLOT_COUNT 个槽位，槽位 i 把房主本机 UDP 33771 映射到服务器 UDP
 * FIRST_GAME_PORT + i，并把一张 JSON 房间卡发布在服务器 TCP FIRST_CARD_PORT + i；
 * 其他玩家探测这些 TCP 端口列出房间，直接连服务器的 UDP 端口加入。只有房主运行 frp。
 * 游戏侧由联机组件 MOD（online-mod/STS2CottageOnline）读取 pending-action.json 开房 / 加入。
 */
const fs = require('fs');
const path = require('path');
const net = require('net');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');

const LOCAL_GAME_PORT = 33771; // 游戏自带 ENet 开房端口，各端相同
const FIRST_GAME_PORT = 33771; // 服务器 UDP，frps allowPorts
const FIRST_CARD_PORT = 34771; // 服务器 TCP，frps allowPorts
const SLOT_COUNT = 20;
const SCAN_TIMEOUT_MS = 2500;
const START_TIMEOUT_MS = 20000;
const MAX_CARD_BYTES = 8192;
const MOD_ID = 'STS2CottageOnline';
const MOD_FILES = [`${MOD_ID}.dll`, `${MOD_ID}.json`];

/** 构建时由 scripts/prepare-assets.js 从 .env（STS2_FRP_SERVER / _PORT / _TOKEN）写入，不入库。 */
function loadServerConfig(file) {
	try {
		const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
		const port = Number.parseInt(raw.serverPort, 10);
		if (typeof raw.server === 'string' && raw.server.trim()) {
			return { server: raw.server.trim(), serverPort: Number.isFinite(port) ? port : 7000, token: String(raw.token || '') };
		}
	} catch (error) {
		// 未配置。
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
		socket.on('error', () => finish(null));
		function parse() {
			try {
				const info = JSON.parse(Buffer.concat(chunks).subarray(0, MAX_CARD_BYTES).toString('utf8'));
				return info && typeof info === 'object' && !Array.isArray(info) ? info : null;
			} catch (error) {
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
			socket.on('error', () => {});
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
				await this.start(slot, nickname, version, continuing);
				this.room = { slot, port: FIRST_GAME_PORT + slot, name: `${nickname}的房间` };
				this.setState('running');
				return this.room;
			} catch (startError) {
				error = startError.message;
				this.stopProcesses();
				if (!isTakenError(error)) {
					break;
				}
			}
		}
		this.setState('idle');
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
			child.stdin.on('error', () => {});
			child.once('error', error => settle(reject, error));
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
						continue;
					}
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
				// 已退出。
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

/** 当前账号是否有未完成的多人存档（profileN/saves/current_run_mp.save），用于房间卡“继续存档”。 */
function hasMultiplayerSave(accountDir) {
	if (!accountDir) {
		return false;
	}
	let entries;
	try {
		entries = fs.readdirSync(accountDir, { withFileTypes: true });
	} catch (error) {
		return false;
	}
	return entries.some(entry => entry.isDirectory() && entry.name.startsWith('profile')
		&& ['current_run_mp.save', 'current_run_mp.save.backup'].some(name => fs.existsSync(path.join(accountDir, entry.name, 'saves', name))));
}

/** 一次性指令，游戏主菜单就绪时由联机组件读取并删除（user://launcher/pending-action.json）。 */
function pendingActionPath(saveRoot) {
	return path.join(saveRoot, 'launcher', 'pending-action.json');
}

function writePendingAction(saveRoot, action) {
	const file = pendingActionPath(saveRoot);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const temp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(temp, JSON.stringify({ v: 1, created: Math.floor(Date.now() / 1000), ...action }), 'utf8');
	fs.renameSync(temp, file);
}

function clearPendingAction(saveRoot) {
	fs.rmSync(pendingActionPath(saveRoot), { force: true });
}

/** 把联机组件复制到 <游戏目录>/mods/STS2CottageOnline/（内容相同则不动）；返回是否有更新。 */
function installOnlineMod(sourceDir, modsDir) {
	for (const name of MOD_FILES) {
		if (!fs.existsSync(path.join(sourceDir, name))) {
			throw new Error('online_component_missing');
		}
	}
	const target = path.join(modsDir, MOD_ID);
	fs.mkdirSync(target, { recursive: true });
	let changed = false;
	for (const name of MOD_FILES) {
		const from = path.join(sourceDir, name);
		const to = path.join(target, name);
		const incoming = fs.readFileSync(from);
		if (fs.existsSync(to) && fs.readFileSync(to).equals(incoming)) {
			continue;
		}
		const temp = `${to}.${process.pid}.tmp`;
		fs.writeFileSync(temp, incoming);
		fs.renameSync(temp, to);
		changed = true;
	}
	return changed;
}

module.exports = {
	LOCAL_GAME_PORT,
	FIRST_GAME_PORT,
	FIRST_CARD_PORT,
	SLOT_COUNT,
	MOD_ID,
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
	pendingActionPath,
	writePendingAction,
	clearPendingAction,
	installOnlineMod,
};
