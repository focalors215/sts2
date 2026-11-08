'use strict';

const path = require('path');
const fs = require('fs');
const { app, BrowserWindow, ipcMain, dialog, shell, nativeTheme, safeStorage } = require('electron');
const { LauncherConfig } = require('./config');
const game = require('./game');
const mods = require('./mods');
const saves = require('./saves');
const online = require('./online');
const { Logger, setShared, log } = require('./logger');
const logfiles = require('./logfiles');
const crash = require('./crash');
const llm = require('./llm');
const workshop = require('./workshop');
const webdav = require('./webdav');
const nexus = require('./nexus');
const updater = require('./update');
const backup = require('./backup');
const files = require('./files');
const { SecretStore } = require('./secrets');

const COTTAGE_BACKGROUND = '#121A33';
const COTTAGE_INK = '#FFF1D6';

let mainWindow = null;
let config = null;
let gameRunning = false;
let roomHost = null;
let frpToken = '';
let gameWatchTimer = null;
let secrets = null;
// 日志 AI 分析会话（只在内存里）：{ session, controller, files, endpoint }
let aiState = null;
const profileInfoCache = new Map();

/** 打包后在 resources/，开发时在 windows/resources/（tools/windows/build-*.sh 生成）。 */
function resourceDir(...parts) {
	return path.join(app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources'), ...parts);
}

const onlinePaths = {
	helper: () => process.env.STS2_FRPC_HELPER || resourceDir('frp', 'sts2-frpc.exe'),
	mods: () => process.env.STS2_ONLINE_MOD_DIR || resourceDir('online-mod'),
	server: () => path.join(__dirname, '..', '..', 'assets', 'generated', 'online.json'),
};

function dataDir() {
	return app.getPath('userData');
}

function createWindow() {
	nativeTheme.themeSource = 'dark';
	mainWindow = new BrowserWindow({
		width: 1280,
		height: 820,
		minWidth: 420,
		minHeight: 560,
		backgroundColor: COTTAGE_BACKGROUND,
		title: 'STS2 小屋启动器',
		icon: path.join(__dirname, '..', '..', 'assets', 'generated', 'icon.png'),
		titleBarStyle: 'hidden',
		titleBarOverlay: { color: '#00000000', symbolColor: COTTAGE_INK, height: 34 },
		show: false,
		webPreferences: {
			preload: path.join(__dirname, 'preload.js'),
			contextIsolation: true,
			nodeIntegration: false,
			sandbox: true,
		},
	});
	mainWindow.removeMenu();
	mainWindow.once('ready-to-show', () => mainWindow.show());
	mainWindow.webContents.setWindowOpenHandler(({ url }) => {
		if (/^https:\/\//.test(url)) {
			shell.openExternal(url);
		}
		return { action: 'deny' };
	});
	mainWindow.webContents.on('will-navigate', event => event.preventDefault());
	mainWindow.webContents.on('render-process-gone', (event, details) => log().e('ui', `渲染进程退出: ${details.reason}（代码 ${details.exitCode}）`));
	mainWindow.webContents.on('unresponsive', () => log().w('ui', '窗口无响应'));
	mainWindow.webContents.on('console-message', (event, ...legacy) => {
		// Electron 35+ 把信息放在 event 上；旧签名为 (event, level, message, line, sourceId)。
		const level = event.level !== undefined ? event.level : ['debug', 'info', 'warning', 'error'][legacy[0]];
		const message = event.message !== undefined ? event.message : legacy[1];
		if (level === 'error' || level === 'warning') {
			log().write(level === 'error' ? 'E' : 'W', 'ui', `渲染进程控制台: ${message} (${event.sourceId || legacy[3] || ''}:${event.lineNumber || legacy[2] || ''})`);
		}
	});
	mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
	if (process.env.STS2_LAUNCHER_SNAPSHOT_DIR) {
		mainWindow.webContents.once('did-finish-load', () => captureSnapshots().catch(error => log().e('ui', '界面截图失败', error)));
	}
}

/**
 * 开发用：STS2_LAUNCHER_SNAPSHOT_DIR=<目录> STS2_LAUNCHER_SNAPSHOT_TABS=logs,network 时依次打开这些页面、
 * 截图保存为 <tab>.png 后退出，用来在没有 Windows 的机器上检查界面。
 */
async function captureSnapshots() {
	const dir = process.env.STS2_LAUNCHER_SNAPSHOT_DIR;
	const tabs = (process.env.STS2_LAUNCHER_SNAPSHOT_TABS || 'home').split(',').filter(Boolean);
	const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
	fs.mkdirSync(dir, { recursive: true });
	await wait(1500);
	for (const tab of tabs) {
		const [name, script] = tab.split(':');
		await mainWindow.webContents.executeJavaScript(`openTab(${JSON.stringify(name)}); ${script ? decodeURIComponent(script) : ''}`);
		await wait(1800);
		const image = await mainWindow.webContents.capturePage();
		fs.writeFileSync(path.join(dir, `${name}.png`), image.toPNG());
	}
	app.quit();
}

function currentProfile() {
	const profile = config.selectedProfile();
	if (!profile) {
		throw new Error('no_profile');
	}
	return profile;
}

async function modsView(accountOverride) {
	const profile = config.selectedProfile();
	if (!profile) {
		return null;
	}
	const info = await game.inspectGameDir(profile.gameDir);
	const account = accountOverride || saves.selectedAccount(config.settings).account;
	let settingsJson = null;
	try {
		settingsJson = saves.readSettingsSave(account);
	} catch (error) {
		log().w('mods', `读取 settings.save 失败，MOD 开关暂不可用: ${account && account.path}`, error);
		settingsJson = null;
	}
	return mods.describeMods(info.modsDir, settingsJson, info.version);
}

/** 修改 settings.save 里的 MOD 设置：读 → 改 → 原子写。 */
function editSettingsSave(mutator, accountOverride) {
	const account = accountOverride || saves.selectedAccount(config.settings).account;
	const json = saves.readSettingsSave(account);
	if (!json) {
		throw new Error('no_settings_save');
	}
	mutator(json);
	saves.writeSettingsSave(account, json);
}

/**
 * 游戏实际使用的存档账号：直接运行 exe 时游戏用 default/<n>，通过 Steam 启动时用 steam/<id>。
 * 启动器其它页面仍按“最近修改”选择账号，这里按启动方式挑，避免把联机组件启用写到游戏不会读的目录。
 */
function onlineAccount(profile) {
	const { accounts, account } = saves.selectedAccount(config.settings);
	const preferSteam = !!(profile && profile.launchViaSteam);
	const preferred = accounts.find(candidate => (preferSteam ? candidate.id.startsWith('steam/') : candidate.id.startsWith('default/')));
	return preferred || account;
}

async function buildState() {
	const profile = config.selectedProfile();
	const profiles = await Promise.all(config.data.profiles.map(async p => ({ ...p, info: await game.inspectGameDir(p.gameDir) })));
	profiles.forEach(p => profileInfoCache.set(p.id, p.info));
	const saveState = saves.selectedAccount(config.settings);
	const modState = await modsView();
	return {
		platform: process.platform,
		appVersion: app.getVersion(),
		welcomeDone: config.data.welcomeDone,
		lastTab: config.data.lastTab,
		settings: config.settings,
		profiles,
		selectedProfileId: profile ? profile.id : '',
		gameRunning,
		saves: {
			root: saveState.root,
			rootExists: fs.existsSync(saveState.root),
			accounts: saveState.accounts.map(a => ({ id: a.id, mtimeMs: a.mtimeMs })),
			account: saveState.account ? saveState.account.id : '',
			snapshots: saves.listSnapshots(dataDir(), saveState.account).map(s => ({ name: s.name, size: s.size, mtimeMs: s.mtimeMs, reason: s.reason })),
		},
		mods: modState && { ...modState, mods: modState.mods.map(({ directory, manifestPath, ...rest }) => rest) },
		dataDir: dataDir(),
		online: onlineState(profile, saveState.account),
		updateSettings: { autoCheck: config.section('update').autoCheck !== false },
		crashes: crash.unacknowledgedReports(dataDir()).map(report => ({ name: report.name, kind: report.kind, detectedAt: report.detectedAt, reason: report.reason, exitCode: report.exitCode })),
	};
}

function onlineState(profile, account) {
	const serverConfig = online.loadServerConfig(onlinePaths.server());
	const info = profile && profileInfoCache.get(profile.id);
	const version = (info && info.version) || '';
	return {
		configured: !!serverConfig,
		tokenReady: !!frpToken,
		server: serverConfig ? serverConfig.server : '',
		modReady: online.componentReady(onlinePaths.mods(), version),
		bundledVersions: online.bundledComponentVersions(onlinePaths.mods()),
		supportedVersions: online.SUPPORTED_VERSIONS,
		modInstalled: online.componentInstalled(info && info.modsDir),
		helperReady: fs.existsSync(onlinePaths.helper()),
		nickname: config.online.nickname,
		lanHost: config.online.lanHost,
		lanPort: config.online.lanPort,
		lanAddresses: online.localIpv4Addresses(),
		gamePort: online.LOCAL_GAME_PORT,
		gameVersion: version,
		versionSupported: online.supportsVersion(version),
		continuing: online.hasMultiplayerSave(account && account.path),
		hosting: roomHost ? { state: roomHost.state, room: roomHost.room } : { state: 'idle', room: null },
	};
}

// 可预期的用户错误（界面会给出中文提示），记 W；其余记 E 并带堆栈。
const EXPECTED_ERRORS = new Set(['update_network', 'backup_invalid', 'files_bad_path', 'files_bad_root', 'files_protected', 'files_not_file', 'files_too_large', 'files_binary', 'files_changed', 'files_bad_json', 'nexus_no_key', 'nexus_bad_key', 'nexus_premium_required', 'nexus_not_found', 'nexus_rate_limited', 'nexus_network', 'nexus_bad_nxm', 'nexus_no_links', 'mods_unsupported_archive', 'webdav_not_configured', 'webdav_bad_url', 'webdav_auth', 'webdav_network', 'workshop_network', 'workshop_bad_ref', 'workshop_not_found', 'workshop_not_downloaded', 'ai_no_session', 'ai_busy', 'secret_store_unavailable', 'no_profile', 'game_not_ready', 'game_running', 'no_settings_save', 'no_manifest', 'online_not_configured',
	'online_token_required', 'online_component_missing', 'online_no_settings', 'online_bad_address', 'online_unsupported_version']);

function handle(channel, fn) {
	ipcMain.handle(channel, async (event, ...args) => {
		try {
			return { ok: true, value: await fn(...args) };
		} catch (error) {
			const message = error && error.message ? error.message : String(error);
			const tag = channelTag(channel);
			if (EXPECTED_ERRORS.has(message)) {
				log().w(tag, `${channel} 失败: ${message}`, error.cause);
			} else {
				log().e(tag, `${channel} 失败`, error);
			}
			return { ok: false, error: message };
		}
	});
}

function channelTag(channel) {
	const prefix = channel.split(':')[0];
	return { backup: 'saves', files: 'saves', online: 'online', mods: 'mods', saves: 'saves', game: 'launch', profiles: 'launch', cloud: 'cloud', workshop: 'workshop', nexus: 'nexus', update: 'update', logs: 'app', shell: 'app' }[prefix] || 'app';
}

function findMod(view, id, relativePath) {
	const mod = view && view.mods.find(m => m.id === id && (!relativePath || m.relativePath === relativePath));
	if (!mod) {
		throw new Error('mod not found');
	}
	return mod;
}

function registerIpc() {
	handle('state', buildState);
	handle('ui:lastTab', tab => config.setLastTab(tab));
	handle('ui:welcomeDone', () => config.setWelcomeDone());
	handle('settings:update', patch => {
		const settings = config.updateSettings(patch || {});
		log().setDebug(settings.logLevel === 'debug' || settings.logLevel === 'very_debug');
		log().i('app', `设置已更新: ${Object.keys(patch || {}).join(', ')}`);
		return settings;
	});
	handle('logs:list', () => logfiles.listLogSources(logRoots()).map(({ path: ignored, ...rest }) => rest));
	handle('logs:read', id => {
		const source = logfiles.findSource(logfiles.listLogSources(logRoots()), id);
		if (!source) {
			throw new Error('log not found');
		}
		const tail = logfiles.readTail(source.path);
		return { ...tail, rows: tail.rows.map(row => ({ ...row, text: log().redact(row.text) })) };
	});
	handle('logs:export', async () => {
		const result = await dialog.showSaveDialog(mainWindow, {
			title: '导出日志',
			defaultPath: path.join(app.getPath('downloads'), logfiles.exportName()),
			filters: [{ name: 'ZIP', extensions: ['zip'] }],
		});
		if (result.canceled || !result.filePath) {
			return null;
		}
		const entries = await logfiles.exportLogs(result.filePath, {
			sources: logfiles.listLogSources(logRoots()),
			diagnostics: await buildDiagnostics(),
			config: config.data,
			redact: text => log().redact(text),
		});
		log().i('app', `已导出日志 ${entries.length} 个条目: ${result.filePath}`);
		shell.showItemInFolder(result.filePath);
		return { file: result.filePath, entries: entries.length };
	});
	handle('logs:write', (level, tag, message, stack) => {
		const error = stack ? Object.assign(new Error(String(message)), { name: 'RendererError', stack: String(stack) }) : null;
		log().write(['D', 'I', 'W', 'E'].includes(level) ? level : 'I', tag || 'ui', String(message).slice(0, 4000), error);
	});
	handle('ai:getConfig', () => {
		const stored = config.section('ai');
		return { baseUrl: stored.baseUrl || '', model: stored.model || '', reasoningEffort: stored.reasoningEffort || '', hasKey: secrets.has('ai.apiKey') };
	});
	handle('ai:saveConfig', patch => {
		const current = config.section('ai');
		const next = llm.normalizeConfig({ ...current, ...patch, apiKey: patch.apiKey === undefined ? '' : patch.apiKey });
		llm.validateConfig(next);
		if (patch.apiKey !== undefined) {
			secrets.set('ai.apiKey', next.apiKey);
		}
		config.updateSection('ai', { baseUrl: next.baseUrl, model: next.model, reasoningEffort: next.reasoningEffort });
		resetAi('配置已变更');
		log().i('app', `AI 分析配置已保存（${llm.endpoint(next)}，模型 ${next.model}）`);
		return true;
	});
	handle('ai:start', ids => {
		resetAi('重新选择日志');
		const sources = logfiles.listLogSources(logRoots());
		const files = (Array.isArray(ids) ? ids : []).map(id => logfiles.findSource(sources, id)).filter(Boolean);
		const stored = config.section('ai');
		const aiConfig = llm.normalizeConfig({ ...stored, apiKey: secrets.get('ai.apiKey') });
		llm.validateConfig(aiConfig);
		const tools = new llm.LogTools(files);
		aiState = {
			session: new llm.ChatSession((messages, defs, signal) => llm.complete(aiConfig, messages, defs, signal), tools, tools.systemPrompt()),
			controller: null,
			files: tools.metadata(),
			endpoint: llm.endpoint(aiConfig),
		};
		log().i('app', `AI 分析会话开始：${files.map(f => f.id).join(', ')} → ${aiState.endpoint}`);
		return { files: aiState.files, endpoint: aiState.endpoint };
	});
	handle('ai:ask', async question => {
		if (!aiState) {
			throw new Error('ai_no_session');
		}
		if (aiState.controller) {
			throw new Error('ai_busy');
		}
		const state = aiState;
		state.controller = new AbortController();
		try {
			const result = await state.session.ask(String(question || '').slice(0, 8000), state.controller.signal, summary => {
				if (mainWindow && !mainWindow.isDestroyed()) {
					mainWindow.webContents.send('ai-progress', summary);
				}
			});
			return result;
		} finally {
			state.controller = null;
		}
	});
	handle('ai:stop', () => resetAi('用户停止', true));
	registerWorkshopIpc();
	registerCloudIpc();
	registerNexusIpc();
	registerToolsIpc();
	handle('crash:ack', names => crash.acknowledgeReports(dataDir(), Array.isArray(names) ? names : []));

	handle('profiles:detect', async () => {
		const found = await game.detectSteamInstalls();
		const added = [];
		for (const install of found) {
			added.push(config.addProfile({ ...install, name: install.steamBranch && install.steamBranch !== 'public' ? `Steam · ${install.steamBranch}` : 'Steam' }));
		}
		return { found: found.length, profiles: added.map(p => p.id) };
	});
	handle('profiles:addFolder', async () => {
		const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'], title: '选择杀戮尖塔 2 游戏目录' });
		if (result.canceled || !result.filePaths[0]) {
			return null;
		}
		const gameDir = result.filePaths[0];
		const info = await game.inspectGameDir(gameDir);
		const profile = config.addProfile({ gameDir, source: 'manual', name: path.basename(gameDir), launchViaSteam: false });
		return { profile, info };
	});
	handle('profiles:select', id => config.selectProfile(id));
	handle('profiles:update', (id, patch) => config.updateProfile(id, patch));
	handle('profiles:remove', id => config.removeProfile(id));

	handle('saves:pickRoot', async () => {
		const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'], defaultPath: saves.defaultSaveRoot() });
		if (result.canceled || !result.filePaths[0]) {
			return null;
		}
		return config.updateSettings({ saveRoot: result.filePaths[0], saveAccount: '' });
	});
	handle('saves:snapshot', async () => {
		const { account } = saves.selectedAccount(config.settings);
		return path.basename(await saves.createSnapshot(dataDir(), account, 'manual', config.settings.snapshotKeep));
	});
	handle('saves:restore', async name => {
		const { account } = saves.selectedAccount(config.settings);
		if (gameRunning) {
			throw new Error('game_running');
		}
		const snapshot = saves.listSnapshots(dataDir(), account).find(s => s.name === name);
		if (!snapshot) {
			throw new Error('snapshot not found');
		}
		await saves.restoreSnapshot(dataDir(), account, snapshot.path, config.settings.snapshotKeep);
	});
	handle('saves:deleteSnapshot', name => {
		const { account } = saves.selectedAccount(config.settings);
		const snapshot = saves.listSnapshots(dataDir(), account).find(s => s.name === name);
		if (snapshot) {
			fs.rmSync(snapshot.path, { force: true });
		}
	});

	handle('mods:setMaster', enabled => editSettingsSave(json => {
		mods.modSettingsOf(json).mods_enabled = !!enabled;
	}));
	handle('mods:setEnabled', (id, enabled) => editSettingsSave(json => mods.setDisabled(json, id, !enabled)));
	handle('mods:fixOrder', async () => {
		const view = await modsView();
		editSettingsSave(json => mods.fixLoadOrder(json, view.mods));
	});
	handle('mods:delete', async (id, relativePath) => {
		const view = await modsView();
		const mod = findMod(view, id, relativePath);
		mods.deleteMod(view.modsDir, mod);
		try {
			editSettingsSave(json => mods.removeFromList(json, id));
		} catch (error) {
			// 没有 settings.save 时只删文件。
			log().d('mods', `删除 MOD ${id} 后未能更新 settings.save`, error);
		}
		log().i('mods', `已删除 MOD ${id}: ${mod.relativePath}`);
	});
	handle('mods:prepareImport', async kind => {
		const result = await dialog.showOpenDialog(mainWindow, kind === 'folder'
			? { properties: ['openDirectory'], title: '选择 MOD 文件夹' }
			: { properties: ['openFile'], filters: [{ name: 'MOD 压缩包', extensions: ['zip'] }], title: '选择 MOD 压缩包' });
		if (result.canceled || !result.filePaths[0]) {
			return null;
		}
		const view = await modsView();
		if (!view) {
			throw new Error('no_profile');
		}
		return mods.prepareImport(path.join(dataDir(), 'mod-staging'), view.modsDir, result.filePaths[0]);
	});
	handle('mods:commitImport', token => {
		const ids = mods.commitImport(token);
		log().i('mods', `已导入 MOD: ${ids.join(', ')}`);
		return ids;
	});
	handle('mods:cancelImport', token => mods.cancelImport(token));

	handle('shell:open', async (target, profileId) => {
		const profile = (profileId && config.data.profiles.find(p => p.id === profileId)) || config.selectedProfile();
		const { root, account } = saves.selectedAccount(config.settings);
		const targets = {
			game: profile && profile.gameDir,
			mods: profile && path.join(profile.gameDir, 'mods'),
			saves: account ? account.path : root,
			snapshots: account ? path.join(dataDir(), 'save-snapshots') : dataDir(),
			data: dataDir(),
			logs: path.join(root, 'logs'),
			launcherLogs: path.join(dataDir(), 'logs'),
		};
		const dir = targets[target];
		if (!dir) {
			throw new Error('unknown target');
		}
		fs.mkdirSync(dir, { recursive: true });
		const error = await shell.openPath(dir);
		if (error) {
			throw new Error(error);
		}
	});
	handle('shell:external', url => {
		if (!/^(https:\/\/|steam:\/\/)/.test(url)) {
			throw new Error('blocked url');
		}
		return shell.openExternal(url);
	});

	handle('game:launch', () => launchCurrent({}));

	handle('online:setNickname', nickname => config.updateOnline({ nickname }));
	handle('online:setFrpToken', token => {
		log().removeSecret(frpToken);
		frpToken = String(token || '').trim();
		log().addSecret(frpToken);
		log().i('online', frpToken ? '已输入 FRP 令牌（仅本次运行）' : '已清除 FRP 令牌');
		return !!frpToken;
	});
	handle('online:scan', () => {
		const serverConfig = online.loadServerConfig(onlinePaths.server());
		if (!serverConfig) {
			throw new Error('online_not_configured');
		}
		return online.scanRooms(serverConfig.server);
	});
	handle('online:create', async () => {
		const serverConfig = online.loadServerConfig(onlinePaths.server());
		if (!serverConfig) {
			throw new Error('online_not_configured');
		}
		if (!frpToken) {
			throw new Error('online_token_required');
		}
		const prepared = await prepareOnlineLaunch();
		if (!roomHost) {
			roomHost = new online.RoomHost({
				helperPath: onlinePaths.helper(),
				workDir: path.join(dataDir(), 'frp'),
				serverConfig: { ...serverConfig, token: frpToken },
				onStateChange: notifyOnline,
			});
		}
		roomHost.serverConfig = { ...serverConfig, token: frpToken };
		const room = await roomHost.create({ nickname: config.online.nickname, version: prepared.version || 'unknown', continuing: prepared.continuing });
		try {
			writeOnlineAction({ type: 'host', online: true });
			return { room, ...prepared, ...(await launchCurrent({ keepLauncher: true })) };
		} catch (error) {
			log().e('online', '开房后启动游戏失败，关闭房间', error);
			roomHost.stop();
			throw error;
		}
	});
	handle('online:join', async (host, port) => {
		const prepared = await prepareOnlineLaunch();
		writeOnlineAction({ type: 'join', online: true, host, port });
		return { ...prepared, ...(await launchCurrent({ keepLauncher: false })) };
	});
	handle('online:hostLan', async () => {
		const prepared = await prepareOnlineLaunch();
		writeOnlineAction({ type: 'host', online: false });
		return { ...prepared, ...(await launchCurrent({ keepLauncher: false })) };
	});
	handle('online:joinLan', async (host, port) => {
		const lanHost = String(host || '').trim().replace(/^\[(.*)\]$/, '$1');
		const lanPort = Number.parseInt(port, 10);
		if (!lanHost || !(lanPort > 0 && lanPort <= 65535)) {
			throw new Error('online_bad_address');
		}
		config.updateOnline({ lanHost, lanPort });
		const prepared = await prepareOnlineLaunch();
		writeOnlineAction({ type: 'join', online: false, host: lanHost, port: lanPort });
		return { ...prepared, ...(await launchCurrent({ keepLauncher: false })) };
	});
	handle('online:stop', () => {
		if (roomHost) {
			log().i('online', '用户关闭房间');
			roomHost.stop();
		}
	});
}

function webdavConfig() {
	const section = config.section('webdav');
	return {
		url: section.url || '',
		username: section.username || '',
		slot: section.slot || '',
		includeSettingsSave: section.includeSettingsSave === true,
		mode: webdav.normalizeCloudMode(section.mode),
	};
}

/** 云同步作用于游戏实际使用的存档账号（同联机：直接启动 default/，Steam 启动 steam/）。 */
function webdavSync() {
	const cfg = webdavConfig();
	if (!cfg.url) {
		throw new Error('webdav_not_configured');
	}
	const profile = config.selectedProfile();
	const account = onlineAccount(profile);
	if (!account) {
		throw new Error('no_settings_save');
	}
	return new webdav.WebDavSync({
		config: { ...cfg, password: secrets.get('webdav.password') },
		accountDir: account.path,
		stateDir: path.join(dataDir(), 'webdav', 'cloud'),
		profileId: profile ? profile.id : 'global',
	});
}

/** 云操作：冲突作为结果返回（界面要让用户选保留哪份），其他错误照常抛出。 */
async function runCloud(name, operation) {
	if (gameRunning) {
		throw new Error('game_running');
	}
	const sync = webdavSync();
	const progress = (percent, message) => {
		if (mainWindow && !mainWindow.isDestroyed()) {
			mainWindow.webContents.send('cloud-progress', { percent, message });
		}
	};
	try {
		const result = await operation(sync, progress);
		config.updateSection('webdav', { [`last_${name}_at`]: Date.now(), lastError: '' });
		log().i('cloud', `WebDAV ${name} 完成: ${JSON.stringify(result)}`);
		return { ok: true, ...result };
	} catch (error) {
		if (error instanceof webdav.CloudConflictError) {
			log().w('cloud', `WebDAV ${name} 冲突 ${error.conflicts.length} 个文件: ${error.conflicts.slice(0, 8).join(', ')}`);
			return { ok: false, conflicts: error.conflicts };
		}
		config.updateSection('webdav', { lastError: error.message });
		throw error;
	}
}

function registerCloudIpc() {
	handle('cloud:getConfig', () => {
		const cfg = webdavConfig();
		const section = config.section('webdav');
		let status = null;
		try {
			status = cfg.url ? webdavSync().status() : null;
		} catch (error) {
			log().d('cloud', '读取 WebDAV 状态失败', error);
		}
		return { ...cfg, hasPassword: secrets.has('webdav.password'), status, lastError: section.lastError || '', lastPull: section.last_pull_at || 0, lastPush: section.last_push_at || 0 };
	});
	handle('cloud:saveConfig', patch => {
		const next = {};
		for (const key of ['url', 'username', 'slot']) {
			if (patch[key] !== undefined) next[key] = String(patch[key]).trim();
		}
		if (next.url) {
			new webdav.WebDavClient({ url: next.url });
		}
		if (patch.includeSettingsSave !== undefined) next.includeSettingsSave = patch.includeSettingsSave === true;
		if (patch.mode !== undefined) next.mode = webdav.normalizeCloudMode(patch.mode);
		if (patch.password !== undefined) {
			secrets.set('webdav.password', String(patch.password));
		}
		config.updateSection('webdav', { ...next, lastError: '' });
		log().i('cloud', `WebDAV 配置已保存: ${Object.keys(next).join(', ')}${patch.password !== undefined ? ', password' : ''}`);
		return true;
	});
	handle('cloud:clear', () => {
		secrets.set('webdav.password', '');
		config.data.webdav = {};
		config.save();
		log().i('cloud', 'WebDAV 设置已清除');
	});
	handle('cloud:test', () => runCloud('test', async sync => ({ remoteDir: await sync.testConnection() })));
	handle('cloud:refresh', () => runCloud('refresh', sync => sync.refresh()));
	handle('cloud:pull', force => runCloud('pull', (sync, progress) => sync.pull(force === true, progress)));
	handle('cloud:push', force => runCloud('push', (sync, progress) => sync.push(force === true, progress)));
}

function nexusClient() {
	return new nexus.NexusClient(secrets.get('nexus.apiKey'), { version: app.getVersion() });
}

// 正在等待确认的 Nexus 安装：导入 token → 下载目录（确认或取消后删除）。
const pendingNexusInstalls = new Map();

function registerNexusIpc() {
	handle('nexus:getConfig', () => ({ hasKey: secrets.has('nexus.apiKey'), user: config.section('nexus').user || '', premium: config.section('nexus').premium === true }));
	handle('nexus:saveKey', async key => {
		const client = new nexus.NexusClient(key, { version: app.getVersion() });
		log().addSecret(String(key || '').trim());
		const user = await client.validate();
		secrets.set('nexus.apiKey', String(key).trim());
		config.updateSection('nexus', { user: user.name, premium: user.premium });
		log().i('nexus', `Nexus API Key 已验证并加密保存（用户 ${user.name}，Premium=${user.premium}）`);
		return user;
	});
	handle('nexus:clearKey', () => {
		secrets.set('nexus.apiKey', '');
		config.updateSection('nexus', { user: '', premium: false });
		log().i('nexus', '已清除 Nexus API Key');
	});
	handle('nexus:discover', () => nexusClient().discover());
	handle('nexus:search', query => nexusClient().search(query));
	handle('nexus:mod', async modId => {
		const client = nexusClient();
		const [mod, files] = await Promise.all([client.getMod(modId), client.files(modId)]);
		return { ...mod, files };
	});
	handle('nexus:prepareInstall', async (modId, fileId, nxmText) => {
		const view = await modsView();
		if (!view) {
			throw new Error('no_profile');
		}
		let nxm = null;
		if (nxmText) {
			nxm = nexus.parseNxmLink(nxmText);
			if (!nxm || nxm.modId !== String(modId) || nxm.fileId !== String(fileId)) {
				throw new Error('nexus_bad_nxm');
			}
		}
		const client = nexusClient();
		const links = await client.downloadLinks(modId, fileId, nxm);
		if (!links.length) {
			throw new Error('nexus_no_links');
		}
		const dir = path.join(dataDir(), 'nexus-downloads', `${modId}-${fileId}-${Date.now()}`);
		log().i('nexus', `下载 Nexus MOD ${modId} 文件 ${fileId}（${links[0].name}）`);
		let file;
		try {
			file = await client.download(links[0].uri, dir, `${modId}-${fileId}.zip`, (received, total) => {
				if (mainWindow && !mainWindow.isDestroyed()) {
					mainWindow.webContents.send('nexus-progress', { received, total });
				}
			});
			if (!/\.zip$/i.test(file)) {
				throw new Error('mods_unsupported_archive');
			}
			const plan = await mods.prepareImport(path.join(dataDir(), 'mod-staging'), view.modsDir, file);
			pendingNexusInstalls.set(plan.token, dir);
			return plan;
		} catch (error) {
			fs.rmSync(dir, { recursive: true, force: true });
			throw error;
		}
	});
	handle('nexus:commitInstall', token => {
		const dir = pendingNexusInstalls.get(token);
		pendingNexusInstalls.delete(token);
		try {
			const ids = mods.commitImport(token);
			log().i('nexus', `已从 Nexus 安装 MOD: ${ids.join(', ')}`);
			return ids;
		} finally {
			if (dir) fs.rmSync(dir, { recursive: true, force: true });
		}
	});
	handle('nexus:cancelInstall', token => {
		const dir = pendingNexusInstalls.get(token);
		pendingNexusInstalls.delete(token);
		mods.cancelImport(token);
		if (dir) fs.rmSync(dir, { recursive: true, force: true });
	});
}

/** 文件浏览允许的根目录。 */
async function fileRoots() {
	const roots = [
		{ id: 'saves', label: 'files_root_saves', path: saves.resolveSaveRoot(config.settings) },
		{ id: 'data', label: 'files_root_data', path: dataDir() },
	];
	const profile = config.selectedProfile();
	if (profile) {
		roots.push({ id: 'mods', label: 'files_root_mods', path: path.join(profile.gameDir, 'mods') });
	}
	return roots;
}

async function checkUpdate(manual) {
	try {
		const result = await updater.checkForUpdate(app.getVersion());
		config.updateSection('update', { lastCheckAt: Date.now(), lastResult: { status: result.status, version: result.version || '' } });
		return result;
	} catch (error) {
		config.updateSection('update', { lastCheckAt: Date.now() });
		if (manual) throw error;
		log().w('update', '自动检查更新失败', error);
		return null;
	}
}

function registerToolsIpc() {
	handle('update:check', () => checkUpdate(true));
	handle('update:settings', patch => config.updateSection('update', { autoCheck: patch && patch.autoCheck !== false }));
	handle('backup:measure', async () => {
		const profile = config.selectedProfile();
		return backup.measure({ saveRoot: saves.resolveSaveRoot(config.settings), modsDir: profile ? path.join(profile.gameDir, 'mods') : '' });
	});
	handle('backup:export', async includeMods => {
		if (gameRunning) {
			throw new Error('game_running');
		}
		const result = await dialog.showSaveDialog(mainWindow, { title: '导出完整数据备份', defaultPath: path.join(app.getPath('documents'), backup.backupName()), filters: [{ name: 'ZIP', extensions: ['zip'] }] });
		if (result.canceled || !result.filePath) {
			return null;
		}
		const profile = config.selectedProfile();
		const manifest = await backup.createBackup(result.filePath, {
			saveRoot: saves.resolveSaveRoot(config.settings),
			launcherConfig: config.data,
			modsDir: profile ? path.join(profile.gameDir, 'mods') : '',
			includeMods: includeMods === true,
			launcherVersion: app.getVersion(),
		});
		log().i('saves', `已导出完整数据备份: ${result.filePath}（${JSON.stringify(manifest.includes)}）`);
		shell.showItemInFolder(result.filePath);
		return { file: result.filePath, ...manifest.includes };
	});
	handle('backup:import', async () => {
		if (gameRunning) {
			throw new Error('game_running');
		}
		const picked = await dialog.showOpenDialog(mainWindow, { title: '选择完整数据备份', properties: ['openFile'], filters: [{ name: 'ZIP', extensions: ['zip'] }] });
		if (picked.canceled || !picked.filePaths[0]) {
			return null;
		}
		const work = path.join(dataDir(), 'restore-work', `full-${Date.now()}`);
		const opened = await backup.openBackup(picked.filePaths[0], work);
		try {
			const profile = config.selectedProfile();
			const saveRoot = saves.resolveSaveRoot(config.settings);
			const modsDir = profile ? path.join(profile.gameDir, 'mods') : '';
			// 恢复前先把当前数据备份一份。
			const safetyDir = path.join(dataDir(), 'full-backups');
			fs.mkdirSync(safetyDir, { recursive: true });
			const safety = path.join(safetyDir, `before-restore-${backup.backupName()}`);
			await backup.createBackup(safety, { saveRoot, launcherConfig: config.data, modsDir, includeMods: false, launcherVersion: app.getVersion() });
			const result = backup.restoreBackup(opened, { saveRoot, modsDir: opened.manifest.includes.mods ? modsDir : '' });
			if (result.launcherConfig) {
				const restored = result.launcherConfig;
				if (restored.settings) config.updateSettings({ ...restored.settings, saveRoot: config.settings.saveRoot });
				if (restored.online) config.updateOnline(restored.online);
				for (const key of ['ai', 'webdav', 'workshop', 'nexus', 'update']) {
					if (restored[key] && typeof restored[key] === 'object') config.updateSection(key, restored[key]);
				}
			}
			log().i('saves', `已恢复完整数据备份 ${picked.filePaths[0]}：存档 ${result.savesRestored} 个文件，MOD ${result.modsRestored} 个文件；恢复前备份 ${safety}`);
			return { savesRestored: result.savesRestored, modsRestored: result.modsRestored, safety: path.basename(safety) };
		} finally {
			fs.rmSync(work, { recursive: true, force: true });
		}
	});
	handle('files:roots', async () => (await fileRoots()).map(root => ({ id: root.id, label: root.label, path: root.path, exists: fs.existsSync(root.path) })));
	handle('files:list', async (rootId, relative) => files.list(await fileRoots(), rootId, relative));
	handle('files:read', async (rootId, relative) => files.readText(await fileRoots(), rootId, relative));
	handle('files:write', async (rootId, relative, text, mtimeMs) => {
		if (gameRunning) {
			throw new Error('game_running');
		}
		const result = files.writeText(await fileRoots(), rootId, relative, text, mtimeMs);
		log().i('saves', `已编辑保存文件 ${rootId}:${relative}`);
		return result;
	});
	handle('files:reveal', async (rootId, relative) => {
		const { full } = files.resolve(await fileRoots(), rootId, relative);
		if (fs.existsSync(full) && fs.statSync(full).isDirectory()) {
			const error = await shell.openPath(full);
			if (error) throw new Error(error);
		} else {
			shell.showItemInFolder(full);
		}
	});
}

/** 启动时自动检查更新（每天最多一次，设置可关闭），有更新时通知界面。 */
function autoCheckUpdate() {
	if (!updater.shouldAutoCheck(config.section('update'))) {
		return;
	}
	setTimeout(async () => {
		const result = await checkUpdate(false);
		if (result && result.status === 'update' && mainWindow && !mainWindow.isDestroyed()) {
			mainWindow.webContents.send('update-available', result);
		}
	}, 5000);
}

/** 干净退出后：本地快照 + WebDAV 自动上传（模式为「启动前拉取 + 干净退出后上传」时），同 Android。 */
async function afterCleanExit() {
	const { account } = saves.selectedAccount(config.settings);
	if (account) {
		try {
			await saves.createSnapshot(dataDir(), account, 'clean-exit', config.settings.snapshotKeep);
		} catch (error) {
			log().e('saves', '干净退出后快照失败', error);
		}
	}
	const cfg = webdavConfig();
	if (!cfg.url || cfg.mode !== 'full_auto') {
		return;
	}
	try {
		const result = await runCloud('push', (sync, progress) => sync.push(false, progress));
		if (mainWindow && !mainWindow.isDestroyed()) {
			mainWindow.webContents.send('cloud-auto', { kind: 'push', result });
		}
	} catch (error) {
		log().e('cloud', '干净退出后自动上传 WebDAV 失败', error);
		if (mainWindow && !mainWindow.isDestroyed()) {
			mainWindow.webContents.send('cloud-auto', { kind: 'push', error: error.message });
		}
	}
}

/** 网络错误统一成可读提示（国内直连 Steam 社区经常被重置）。 */
function workshopNetworkError(error) {
	const code = error && (error.code || (error.cause && error.cause.code));
	if (code || /fetch failed|aborted|timeout/i.test(String(error && error.message))) {
		const wrapped = new Error('workshop_network');
		wrapped.cause = error;
		return wrapped;
	}
	return error;
}

function workshopLibrary() {
	return new workshop.WorkshopLibrary(path.join(dataDir(), 'workshop', 'library.json'));
}

// 正在等待用户确认的创意工坊安装：导入 token → 条目信息。
const pendingWorkshopInstalls = new Map();

function registerWorkshopIpc() {
	handle('workshop:browse', async options => {
		try {
			return await workshop.browse(options || {});
		} catch (error) {
			throw workshopNetworkError(error);
		}
	});
	handle('workshop:item', async ref => {
		const id = workshop.parseWorkshopRef(ref);
		if (!id) {
			throw new Error('workshop_bad_ref');
		}
		try {
			return await workshop.loadItem(id);
		} catch (error) {
			throw workshopNetworkError(error);
		}
	});
	handle('workshop:local', async () => {
		const content = workshop.contentDirs(await game.steamLibraries());
		const profile = config.selectedProfile();
		const info = profile ? await game.inspectGameDir(profile.gameDir) : null;
		const installedIds = new Set(info ? mods.scanManifests(info.modsDir).map(mod => mod.id) : []);
		return {
			steamContent: [...content.values()].map(entry => ({ id: entry.id, mtimeMs: entry.mtimeMs })),
			library: workshopLibrary().list().map(entry => ({ ...entry, present: (entry.modIds || []).some(id => installedIds.has(id)) })),
		};
	});
	handle('workshop:subscribe', id => {
		const clean = workshop.parseWorkshopRef(id);
		if (!clean) {
			throw new Error('workshop_bad_ref');
		}
		log().i('workshop', `在 Steam 客户端打开创意工坊条目 ${clean}`);
		return shell.openExternal(`steam://url/CommunityFilePage/${clean}`);
	});
	handle('workshop:prepareInstall', async id => {
		const clean = workshop.parseWorkshopRef(id);
		const view = await modsView();
		if (!view) {
			throw new Error('no_profile');
		}
		let item = null;
		try {
			item = (await workshop.loadDetails([clean])).get(clean) || null;
		} catch (error) {
			log().w('workshop', `读取条目 ${clean} 详情失败（继续从本地内容安装）`, error);
		}
		const local = workshop.contentDirs(await game.steamLibraries()).get(clean);
		let source;
		let via;
		if (local) {
			source = local.dir;
			via = 'steam_content';
		} else if (item && item.fileUrl) {
			const dir = path.join(dataDir(), 'workshop', 'downloads', clean);
			fs.rmSync(dir, { recursive: true, force: true });
			const name = path.basename(item.fileName || `${clean}.zip`).replace(/[^\w.-]+/g, '_') || `${clean}.zip`;
			log().i('workshop', `下载创意工坊直链 ${clean}: ${item.fileUrl.split('?')[0]}`);
			try {
				source = await workshop.downloadFile(item.fileUrl, path.join(dir, name.toLowerCase().endsWith('.zip') ? name : `${name}.zip`), (received, total) => {
					if (mainWindow && !mainWindow.isDestroyed()) {
						mainWindow.webContents.send('workshop-progress', { id: clean, received, total });
					}
				});
			} catch (error) {
				throw workshopNetworkError(error);
			}
			via = 'file_url';
		} else {
			throw new Error('workshop_not_downloaded');
		}
		const plan = await mods.prepareImport(path.join(dataDir(), 'mod-staging'), view.modsDir, source);
		pendingWorkshopInstalls.set(plan.token, { id: clean, title: item ? item.title : clean, timeUpdated: item ? item.timeUpdated : 0, via, source });
		log().i('workshop', `准备安装创意工坊条目 ${clean}（${via}）: ${plan.incoming.map(m => m.id).join(', ')}`);
		return { ...plan, via };
	});
	handle('workshop:commitInstall', token => {
		const pending = pendingWorkshopInstalls.get(token);
		pendingWorkshopInstalls.delete(token);
		const ids = mods.commitImport(token);
		if (pending) {
			workshopLibrary().record({ id: pending.id, title: pending.title, modIds: ids, timeUpdated: pending.timeUpdated, via: pending.via });
			if (pending.via === 'file_url') {
				fs.rmSync(path.dirname(pending.source), { recursive: true, force: true });
			}
			log().i('workshop', `已安装创意工坊条目 ${pending.id}: ${ids.join(', ')}`);
		}
		return ids;
	});
	handle('workshop:cancelInstall', token => {
		const pending = pendingWorkshopInstalls.get(token);
		pendingWorkshopInstalls.delete(token);
		mods.cancelImport(token);
		if (pending && pending.via === 'file_url') {
			fs.rmSync(path.dirname(pending.source), { recursive: true, force: true });
		}
	});
	handle('workshop:checkUpdates', async () => {
		const entries = workshopLibrary().list();
		let remote;
		try {
			remote = await workshop.loadDetails(entries.map(entry => entry.id));
		} catch (error) {
			throw workshopNetworkError(error);
		}
		const updates = entries.filter(entry => workshop.hasUpdate(entry, remote.get(entry.id))).map(entry => entry.id);
		log().i('workshop', `检查创意工坊更新：${entries.length} 个已下载，${updates.length} 个有更新`);
		return updates;
	});
	handle('workshop:forget', async (id, deleteFiles) => {
		const library = workshopLibrary();
		const entry = library.get(id);
		if (entry && deleteFiles) {
			const view = await modsView();
			for (const modId of entry.modIds || []) {
				const mod = view && view.mods.find(m => m.id === modId);
				if (mod) {
					mods.deleteMod(view.modsDir, mod);
					log().i('mods', `随创意工坊记录删除 MOD ${modId}`);
				}
			}
		}
		library.remove(id);
		log().i('workshop', `已删除创意工坊下载记录 ${id}${deleteFiles ? '（含 MOD 文件）' : ''}`);
	});
}

/** 停止 / 清空 AI 会话。keepSession 为 true 时只中止当前请求。 */
function resetAi(reason, keepSession) {
	if (aiState && aiState.controller) {
		aiState.controller.abort();
		log().i('app', `AI 分析请求已中止（${reason}）`);
	}
	if (!keepSession) {
		aiState = null;
	}
}

/** 写一次性指令到游戏 user://launcher/pending-action.json（规范 §3.3）。 */
function writeOnlineAction(fields) {
	const action = online.buildPendingAction({ ...fields, nickname: config.online.nickname, playerId: config.online.playerId });
	const file = online.writePendingAction(saves.resolveSaveRoot(config.settings), action);
	const where = action.type === 'join' ? ` ${action.host}:${action.port}` : '';
	log().i('online', `写入联机指令 ${action.type}${where}（online=${action.online}）: ${file}`);
	return action;
}

/**
 * 联机前的准备（规范 §4）：按当前启动配置的游戏版本把对应的小屋联机组件装到游戏目录，在游戏
 * 实际使用的存档账号 settings.save 里启用它、禁用 Reforged / 旧 LAN MOD（不删文件）。
 */
async function prepareOnlineLaunch() {
	if (gameRunning) {
		throw new Error('game_running');
	}
	const profile = currentProfile();
	const info = await game.inspectGameDir(profile.gameDir);
	if (!info.ready) {
		throw new Error('game_not_ready');
	}
	if (!online.supportsVersion(info.version)) {
		log().w('online', `游戏版本 ${info.version || '未知'} 不在联机支持列表 ${online.SUPPORTED_VERSIONS.join(' / ')}`);
		throw new Error('online_unsupported_version');
	}
	if (!online.componentReady(onlinePaths.mods(), info.version)) {
		log().e('online', `缺少 ${info.version} 的小屋联机组件构建: ${online.componentSourceDir(onlinePaths.mods(), info.version)}`);
		throw new Error('online_component_missing');
	}
	const account = onlineAccount(profile);
	if (!account || !saves.readSettingsSave(account)) {
		throw new Error('online_no_settings');
	}
	const updated = online.installComponent(onlinePaths.mods(), info.version, info.modsDir);
	log().i('online', `小屋联机组件 ${info.version} ${updated ? '已安装/更新' : '已是最新'}: ${path.join(info.modsDir, online.COTTAGE_MOD_ID)}`);
	const view = await modsView(account);
	let result = null;
	editSettingsSave(json => {
		result = online.enableComponentInSettings(json, mods, view ? view.mods : []);
		mods.fixLoadOrder(json, view ? view.mods : []);
	}, account);
	if (result.disabledConflicts.length) {
		log().w('online', `已在 settings.save 禁用冲突的联机 MOD（未删除文件）: ${result.disabledConflicts.join(', ')}`);
	}
	if (result.disabledOthers.length) {
		log().i('online', `MOD 总开关原本关闭：已打开并禁用其他 MOD: ${result.disabledOthers.join(', ')}`);
	}
	return {
		version: info.version,
		componentUpdated: updated,
		continuing: online.hasMultiplayerSave(account.path),
		disabledConflicts: result.disabledConflicts,
		disabledOthers: result.disabledOthers,
		enabledMods: result.enabledOthers,
	};
}

function notifyOnline() {
	if (mainWindow && !mainWindow.isDestroyed()) {
		mainWindow.webContents.send('online-changed');
	}
}

async function launchCurrent({ keepLauncher }) {
	const profile = currentProfile();
	const info = await game.inspectGameDir(profile.gameDir);
	if (!info.ready) {
		throw new Error('game_not_ready');
	}
	const settings = config.settings;
	if (settings.snapshotBeforeLaunch) {
		const { account } = saves.selectedAccount(settings);
		if (account) {
			try {
				await saves.createSnapshot(dataDir(), account, 'before-launch', settings.snapshotKeep);
			} catch (error) {
				// 快照失败不阻止启动，界面会在下次刷新时看到快照没有增加。
				log().e('saves', '启动前快照失败（继续启动）', error);
			}
		}
	}
	const view = await modsView().catch(error => {
		log().w('mods', '读取 MOD 列表失败（启动标记里不含 MOD 列表）', error);
		return null;
	});
	const enabledMods = view && view.modsEnabled ? view.mods.filter(m => m.enabled).map(m => `${m.id}@${m.version || '?'}`) : [];
	log().i('launch', `启动游戏 ${info.version || '未知版本'}（${profile.launchViaSteam ? 'Steam' : 'exe'}）: ${profile.gameDir}；MOD: ${enabledMods.join(', ') || '无'}`);
	let result;
	try {
		result = await game.launchGame(profile, settings, url => shell.openExternal(url));
	} catch (error) {
		log().e('launch', '启动游戏失败', error);
		try {
			online.clearPendingAction(saves.resolveSaveRoot(settings));
		} catch (clearError) {
			log().w('online', '启动失败后清除联机指令失败', clearError);
		}
		throw error;
	}
	log().i('launch', `已启动: ${result.via}${result.child ? ` pid ${result.child.pid}` : ''}，参数 ${JSON.stringify(result.args)}`);
	if (result.child) {
		gameRunning = true;
		try {
			crash.writeLaunchMarker(dataDir(), {
				pid: result.child.pid,
				via: result.via,
				version: info.version,
				profile: { id: profile.id, name: profile.name, gameDir: profile.gameDir, extraArgs: profile.extraArgs },
				args: result.args,
				mods: enabledMods,
				launcherVersion: app.getVersion(),
			});
		} catch (error) {
			log().e('launch', '写启动标记失败', error);
		}
		result.child.once('exit', (code, signal) => onGameExit(code, signal));
	}
	// 当房主时启动器要保持运行（frp 隧道在启动器里），“关闭”改为最小化。
	if (settings.afterLaunch === 'close' && !keepLauncher) {
		setTimeout(() => app.quit(), 800);
	} else if (settings.afterLaunch !== 'keep' && mainWindow) {
		mainWindow.minimize();
	}
	return { via: result.via, args: result.args };
}

/** 游戏进程退出：0 为正常退出；其他退出码记崩溃报告并提示（规范 §5.4）。 */
function onGameExit(code, signal) {
	gameRunning = false;
	const marker = crash.readLaunchMarker(dataDir());
	crash.clearLaunchMarker(dataDir());
	let report = null;
	if (code === 0) {
		log().i('launch', '游戏正常退出');
		afterCleanExit().catch(error => log().e('cloud', '干净退出后的处理失败', error));
	} else {
		log().e('launch', `游戏异常退出：退出码 ${code}${signal ? `，信号 ${signal}` : ''}`);
		try {
			report = crash.recordCrash(dataDir(), 'game', { reason: 'exit_code', exitCode: code, signal, marker });
		} catch (error) {
			log().e('launch', '写崩溃报告失败', error);
		}
	}
	// 房主退出游戏 = 关闭房间。
	if (roomHost) {
		roomHost.stop();
	}
	if (mainWindow && !mainWindow.isDestroyed()) {
		if (mainWindow.isMinimized()) {
			mainWindow.restore();
		}
		mainWindow.webContents.send('game-exited', report ? { crashed: true, exitCode: code, name: report.name } : { crashed: false });
	}
}

/** 上次启动器关闭时游戏还在跑：轮询进程，退出后清掉标记（拿不到退出码，不判为崩溃）。 */
function watchDetachedGame(marker) {
	gameRunning = true;
	log().i('launch', `检测到游戏仍在运行（pid ${marker.pid}），等待其退出`);
	gameWatchTimer = setInterval(() => {
		if (!crash.isAlive(marker.pid)) {
			clearInterval(gameWatchTimer);
			gameWatchTimer = null;
			gameRunning = false;
			crash.clearLaunchMarker(dataDir());
			log().i('launch', `游戏（pid ${marker.pid}）已退出，启动器未能获取退出码`);
			if (mainWindow && !mainWindow.isDestroyed()) {
				mainWindow.webContents.send('game-exited', { crashed: false });
			}
		}
	}, 5000);
}

/**
 * diagnostics.json（规范 §5.5，字段名与 Android LogExportBundle 一致；平台没有的字段省略，
 * Windows 额外字段放在 windows 下）。
 */
async function buildDiagnostics() {
	const os = require('os');
	const profile = config.selectedProfile();
	const info = profile ? await game.inspectGameDir(profile.gameDir) : null;
	const view = await modsView().catch(error => {
		log().w('mods', '导出诊断时读取 MOD 列表失败', error);
		return null;
	});
	const saveState = saves.selectedAccount(config.settings);
	const gameAccountDir = profile ? onlineAccount(profile) : saveState.account;
	let settingsSave = null;
	try {
		settingsSave = gameAccountDir ? logfiles.redactConfig(saves.readSettingsSave(gameAccountDir)) : null;
	} catch (error) {
		log().w('saves', '导出诊断时读取 settings.save 失败', error);
	}
	const serverConfig = online.loadServerConfig(onlinePaths.server());
	const modId = m => `${m.id}@${m.version || '?'}`;
	return {
		platform: 'windows',
		generatedAt: new Date().toISOString(),
		osVersion: `${typeof os.version === 'function' ? os.version() : process.platform} (${os.release()})`,
		deviceModel: os.cpus().length ? os.cpus()[0].model : '',
		abis: [process.arch],
		launcherVersion: app.getVersion(),
		lastStartupMarker: crash.readLaunchMarker(dataDir()),
		launchProfile: profile ? {
			profileId: profile.id,
			gameVersion: info ? info.version : '',
			name: profile.name,
			gameDir: profile.gameDir,
			launchViaSteam: profile.launchViaSteam,
			extraArgs: profile.extraArgs,
			onlineComponent: info ? online.componentReady(onlinePaths.mods(), info.version) : false,
		} : null,
		mods: view ? {
			loadingEnabled: view.modsEnabled,
			enabled: view.mods.filter(m => m.enabled).map(modId),
			disabled: view.mods.filter(m => !m.enabled).map(modId),
		} : null,
		online: {
			configured: !!serverConfig,
			server: serverConfig ? serverConfig.server : '',
			nickname: config.online.nickname,
			playerId: config.online.playerId,
			hostTokenSaved: !!frpToken,
		},
		settings: settingsSave,
		windows: {
			electron: process.versions.electron,
			memoryBytes: os.totalmem(),
			dataDir: dataDir(),
			launcherSettings: config.settings,
			game: info ? { branch: info.branch, commit: info.commit, ready: info.ready, missing: info.missing, dllSha256: info.dllSha256 } : null,
			saves: { root: saveState.root, account: saveState.account ? saveState.account.id : '', gameAccount: gameAccountDir ? gameAccountDir.id : '', accounts: saveState.accounts.map(a => a.id) },
			onlineComponentVersions: online.bundledComponentVersions(onlinePaths.mods()),
			onlineComponentInstalled: !!(info && online.componentInstalled(info.modsDir)),
			frpHelperReady: fs.existsSync(onlinePaths.helper()),
			hosting: roomHost ? { state: roomHost.state, room: roomHost.room } : null,
			gameRunning,
			crashReports: crash.listCrashReports(dataDir()).map(r => r.name),
		},
	};
}

function logRoots() {
	return { dataDir: dataDir(), saveRoot: saves.resolveSaveRoot(config.settings) };
}

// 开发 / 测试：STS2_LAUNCHER_DATA_DIR 指定独立的启动器数据目录，不碰真实配置。
if (process.env.STS2_LAUNCHER_DATA_DIR) {
	app.setPath('userData', path.resolve(process.env.STS2_LAUNCHER_DATA_DIR));
}

function initLogging() {
	const logger = new Logger({ dir: path.join(dataDir(), 'logs') });
	setShared(logger);
	process.on('uncaughtException', error => log().e('app', '主进程未捕获异常', error));
	process.on('unhandledRejection', reason => log().e('app', '主进程未处理的 Promise 拒绝', reason instanceof Error ? reason : new Error(String(reason))));
	log().i('app', `启动器启动 v${app.getVersion()}，${process.platform} ${require('os').release()}，Electron ${process.versions.electron}`);
}

/** 清掉上次遗留的联机指令（启动器异常退出或游戏没到主菜单时会留下），避免下次普通启动误开房。 */
function clearStaleOnlineAction() {
	try {
		const left = online.clearPendingAction(saves.resolveSaveRoot(config.settings));
		if (left !== null) {
			log().w('online', `清除遗留的联机指令: ${left.slice(0, 300)}`);
		}
	} catch (error) {
		log().e('online', '清除遗留联机指令失败', error);
	}
}

/** 上次的启动器会话 / 游戏标记（规范 §5.4）。 */
function checkPreviousRun() {
	try {
		const result = crash.checkPreviousRun(dataDir());
		for (const report of result.reports) {
			log().w(report.kind === 'launcher' ? 'app' : 'launch', report.kind === 'launcher'
				? `上次启动器没有正常退出（会话开始于 ${report.session && report.session.startedAt}）`
				: `上次游戏异常退出：启动器没有记录到它的退出（启动于 ${report.marker && report.marker.startedAt}）`);
		}
		if (result.clearedUnknown) {
			log().i('launch', `上次关闭启动器时游戏仍在运行（pid ${result.clearedUnknown.pid}），无法得知其退出码`);
		}
		if (result.gameStillRunning) {
			watchDetachedGame(result.gameStillRunning);
		}
	} catch (error) {
		log().e('app', '检查上次运行状态失败', error);
	}
	try {
		crash.startSession(dataDir(), { version: app.getVersion() });
	} catch (error) {
		log().e('app', '写启动器会话标记失败', error);
	}
}

app.whenReady().then(() => {
	initLogging();
	config = new LauncherConfig(dataDir());
	secrets = new SecretStore(path.join(dataDir(), 'secrets.json'), safeStorage);
	log().setDebug(config.settings.logLevel === 'debug' || config.settings.logLevel === 'very_debug');
	checkPreviousRun();
	clearStaleOnlineAction();
	registerIpc();
	createWindow();
	autoCheckUpdate();
}).catch(error => log().e('app', '启动器初始化失败', error));

app.on('child-process-gone', (event, details) => log().e('app', `子进程退出: ${details.type} ${details.reason}（代码 ${details.exitCode}）`));

app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => {
	if (roomHost) {
		roomHost.stop();
	}
	try {
		if (gameRunning) {
			// 启动器先于游戏关闭：下次打开时只能靠进程号判断，拿不到退出码。
			crash.updateLaunchMarker(dataDir(), { launcherClosed: true });
		}
		crash.endSession(dataDir());
	} catch (error) {
		log().e('app', '关闭会话标记失败', error);
	}
	log().i('app', '启动器退出');
});
