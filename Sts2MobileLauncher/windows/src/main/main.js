'use strict';

const path = require('path');
const fs = require('fs');
const { app, BrowserWindow, ipcMain, dialog, shell, nativeTheme } = require('electron');
const { LauncherConfig } = require('./config');
const game = require('./game');
const mods = require('./mods');
const saves = require('./saves');

const COTTAGE_BACKGROUND = '#121A33';
const COTTAGE_INK = '#FFF1D6';

let mainWindow = null;
let config = null;
let gameRunning = false;

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

async function modsView() {
	const profile = config.selectedProfile();
	if (!profile) {
		return null;
	}
	const info = await game.inspectGameDir(profile.gameDir);
	const { account } = saves.selectedAccount(config.settings);
	let settingsJson = null;
	try {
		settingsJson = saves.readSettingsSave(account);
	} catch (error) {
		settingsJson = null;
	}
	return mods.describeMods(info.modsDir, settingsJson, info.version);
}

/** 修改 settings.save 里的 MOD 设置：读 → 改 → 原子写。 */
function editSettingsSave(mutator) {
	const { account } = saves.selectedAccount(config.settings);
	const json = saves.readSettingsSave(account);
	if (!json) {
		throw new Error('no_settings_save');
	}
	mutator(json);
	saves.writeSettingsSave(account, json);
}

async function buildState() {
	const profile = config.selectedProfile();
	const profiles = await Promise.all(config.data.profiles.map(async p => ({ ...p, info: await game.inspectGameDir(p.gameDir) })));
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

	handle('game:launch', async () => {
		const profile = currentProfile();
		const info = await game.inspectGameDir(profile.gameDir);
		if (!info.ready && !profile.launchViaSteam) {
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
				if (mainWindow) {
					if (mainWindow.isMinimized()) {
						mainWindow.restore();
					}
					mainWindow.webContents.send('game-exited');
				}
			});
		}
		if (settings.afterLaunch === 'close') {
			setTimeout(() => app.quit(), 800);
		} else if (settings.afterLaunch === 'minimize' && mainWindow) {
			mainWindow.minimize();
		}
		return { via: result.via, args: result.args };
	});
}

app.whenReady().then(() => {
	config = new LauncherConfig(dataDir());
	registerIpc();
	createWindow();
});

app.on('window-all-closed', () => app.quit());
