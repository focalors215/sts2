'use strict';

const path = require('path');
const fs = require('fs');
const { app, BrowserWindow, ipcMain, dialog, shell, nativeTheme } = require('electron');
const { LauncherConfig } = require('./config');
const game = require('./game');
const mods = require('./mods');
const saves = require('./saves');
const online = require('./online');

const COTTAGE_BACKGROUND = '#121A33';
const COTTAGE_INK = '#FFF1D6';

let mainWindow = null;
let config = null;
let gameRunning = false;
let roomHost = null;
let frpToken = '';
const profileInfoCache = new Map();

/** 打包后在 resources/，开发时在 windows/resources/（tools/windows/build-*.sh 生成）。 */
function resourceDir(...parts) {
	return path.join(app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources'), ...parts);
}

const onlinePaths = {
	helper: () => process.env.STS2_FRPC_HELPER || resourceDir('frp', 'sts2-frpc.exe'),
	mods: () => resourceDir('online-mod'),
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
	mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
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
 * 启动器其它页面仍按“最近修改”选择账号，这里按启动方式挑，避免 MOD 启用和 lan_settings.json
 * 写到游戏不会读的目录。
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
		modReady: online.modsReady(onlinePaths.mods()),
		modInstalled: online.modsInstalled(info && info.modsDir),
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

function handle(channel, fn) {
	ipcMain.handle(channel, async (event, ...args) => {
		try {
			return { ok: true, value: await fn(...args) };
		} catch (error) {
			return { ok: false, error: error && error.message ? error.message : String(error) };
		}
	});
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
	handle('settings:update', patch => config.updateSettings(patch || {}));

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
		}
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
	handle('mods:commitImport', token => mods.commitImport(token));
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
		frpToken = String(token || '').trim();
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
		const account = onlineAccount(currentProfile());
		// 房主用固定端口开房，frp 隧道映射的就是它；地址留给加入方，这里不写。
		online.writeLanSettings(account.path, {
			host_port: online.LOCAL_GAME_PORT,
			player_name: config.online.nickname,
		});
		if (!roomHost) {
			roomHost = new online.RoomHost({
				helperPath: onlinePaths.helper(),
				workDir: path.join(dataDir(), 'frp'),
				serverConfig: { ...serverConfig, token: frpToken },
				onStateChange: notifyOnline,
			});
		}
		roomHost.serverConfig = { ...serverConfig, token: frpToken };
		const room = await roomHost.create({ nickname: config.online.nickname, version: prepared.version || 'unknown', continuing: online.hasMultiplayerSave(account.path) });
		try {
			return { room, ...prepared, ...(await launchOnline(true)) };
		} catch (error) {
			roomHost.stop();
			throw error;
		}
	});
	handle('online:join', async (host, port) => {
		await prepareOnlineLaunch();
		online.writeLanSettings(onlineAccount(currentProfile()).path, {
			ip_address: online.joinAddress(host, port),
			host_port: Number(port),
			player_name: config.online.nickname,
		});
		return launchOnline(false);
	});
	handle('online:hostLan', async () => {
		const prepared = await prepareOnlineLaunch();
		online.writeLanSettings(onlineAccount(currentProfile()).path, {
			host_port: online.LOCAL_GAME_PORT,
			player_name: config.online.nickname,
		});
		return { ...prepared, ...(await launchOnline(false)) };
	});
	handle('online:joinLan', async (host, port) => {
		const lanHost = String(host || '').trim().replace(/^\[(.*)\]$/, '$1');
		const lanPort = Number.parseInt(port, 10);
		if (!lanHost || !(lanPort > 0 && lanPort <= 65535)) {
			throw new Error('online_bad_address');
		}
		config.updateOnline({ lanHost, lanPort });
		const prepared = await prepareOnlineLaunch();
		online.writeLanSettings(onlineAccount(currentProfile()).path, {
			ip_address: online.joinAddress(lanHost, lanPort),
			host_port: lanPort,
			player_name: config.online.nickname,
		});
		return { ...prepared, ...(await launchOnline(false)) };
	});
	handle('online:stop', () => {
		if (roomHost) {
			roomHost.stop();
		}
	});
}

/**
 * 联机前的准备：把 Reforged MOD 与 BaseLib 装到游戏目录并在 settings.save 里启用。
 * MOD 总开关原本关着时，打开总开关并把其他玩法 MOD 设为禁用，避免它们随之加载导致
 * 双方 MOD 不一致；同时关掉旧的 LAN MOD 和早期的 STS2CottageOnline，避免两套补丁同时生效。
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
		throw new Error('online_unsupported_version');
	}
	const account = onlineAccount(profile);
	if (!account || !saves.readSettingsSave(account)) {
		throw new Error('online_no_settings');
	}
	const updated = online.installLanMods(onlinePaths.mods(), info.modsDir);
	const view = await modsView(account);
	const disabledOthers = [];
	editSettingsSave(json => {
		const modSettings = mods.modSettingsOf(json);
		const keep = new Set([online.LAN_MOD_ID, online.BASE_LIB_ID]);
		if (!modSettings.mods_enabled) {
			modSettings.mods_enabled = true;
			for (const mod of view ? view.mods : []) {
				if (!keep.has(mod.id) && mod.enabled) {
					mods.setDisabled(json, mod.id, true);
					disabledOthers.push(mod.name || mod.id);
				}
			}
		}
		mods.setDisabled(json, online.LAN_MOD_ID, false);
		mods.setDisabled(json, online.BASE_LIB_ID, false);
		mods.setDisabled(json, online.LEGACY_LAN_MOD_ID, true);
		mods.setDisabled(json, online.COTTAGE_MOD_ID, true);
		mods.fixLoadOrder(json, view.mods);
	}, account);
	const gameplayMods = view ? view.mods.filter(m => !keep.has(m.id) && m.enabled
		&& !disabledOthers.includes(m.name || m.id)).map(m => m.name || m.id) : [];
	return { version: info.version, componentUpdated: updated, disabledOthers, enabledMods: gameplayMods };
}

async function launchOnline(hosting) {
	return launchCurrent({ keepLauncher: hosting });
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
			}
		}
	}
	const result = await game.launchGame(profile, settings, url => shell.openExternal(url));
	if (result.child) {
		gameRunning = true;
		result.child.once('exit', () => {
			gameRunning = false;
			// 房主退出游戏 = 关闭房间。
			if (roomHost) {
				roomHost.stop();
			}
			if (mainWindow) {
				if (mainWindow.isMinimized()) {
					mainWindow.restore();
				}
				mainWindow.webContents.send('game-exited');
			}
		});
	}
	// 当房主时启动器要保持运行（frp 隧道在启动器里），“关闭”改为最小化。
	if (settings.afterLaunch === 'close' && !keepLauncher) {
		setTimeout(() => app.quit(), 800);
	} else if (settings.afterLaunch !== 'keep' && mainWindow) {
		mainWindow.minimize();
	}
	return { via: result.via, args: result.args };
}

app.whenReady().then(() => {
	config = new LauncherConfig(dataDir());
	registerIpc();
	createWindow();
});

app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => {
	if (roomHost) {
		roomHost.stop();
	}
});
