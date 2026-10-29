'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile, spawn } = require('child_process');
const { parseVdf, getKey } = require('./vdf');

const STEAM_APP_ID = '2868840';
const GAME_EXE = 'SlayTheSpire2.exe';
const DATA_DIR = 'data_sts2_windows_x86_64';
// 与 Android PayloadManager / validate_payload_zip.py 的必需文件一致，另加 Windows 可执行文件。
const REQUIRED_FILES = [
	GAME_EXE,
	'SlayTheSpire2.pck',
	'release_info.json',
	`${DATA_DIR}/sts2.dll`,
];
const LOG_TYPES = ['Generic', 'Network', 'Actions', 'GameSync', 'VisualSync'];

const shaCache = new Map();

function readRegistrySteamPath() {
	if (process.platform !== 'win32') {
		return Promise.resolve([]);
	}
	const queries = [
		['HKCU\\Software\\Valve\\Steam', 'SteamPath'],
		['HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam', 'InstallPath'],
		['HKLM\\SOFTWARE\\Valve\\Steam', 'InstallPath'],
	];
	return Promise.all(queries.map(([key, value]) => new Promise(resolve => {
		execFile('reg', ['query', key, '/v', value], { windowsHide: true }, (error, stdout) => {
			if (error) {
				resolve(null);
				return;
			}
			const match = /REG_SZ\s+(.+)$/m.exec(stdout);
			resolve(match ? path.normalize(match[1].trim()) : null);
		});
	}))).then(results => results.filter(Boolean));
}

function defaultSteamRoots() {
	const roots = [];
	if (process.platform === 'win32') {
		roots.push(path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Steam'));
		roots.push(path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Steam'));
	} else if (process.env.HOME) {
		roots.push(path.join(process.env.HOME, '.steam', 'steam'));
		roots.push(path.join(process.env.HOME, '.local', 'share', 'Steam'));
	}
	return roots;
}

function libraryFolders(steamRoot) {
	const folders = [steamRoot];
	try {
		const vdf = parseVdf(fs.readFileSync(path.join(steamRoot, 'steamapps', 'libraryfolders.vdf'), 'utf8'));
		const libraries = getKey(vdf, 'libraryfolders') || {};
		for (const entry of Object.values(libraries)) {
			const folder = typeof entry === 'string' ? entry : getKey(entry, 'path');
			if (typeof folder === 'string' && folder) {
				folders.push(path.normalize(folder));
			}
		}
	} catch (error) {
		// 没有 libraryfolders.vdf 时只看 Steam 根目录。
	}
	return folders;
}

/** 找出本机所有 Steam 库里安装的 STS2。 */
async function detectSteamInstalls() {
	const roots = [...await readRegistrySteamPath(), ...defaultSteamRoots()];
	const seen = new Set();
	const installs = [];
	for (const root of roots) {
		for (const library of libraryFolders(root)) {
			const key = process.platform === 'win32' ? library.toLowerCase() : library;
			if (seen.has(key)) {
				continue;
			}
			seen.add(key);
			const manifestFile = path.join(library, 'steamapps', `appmanifest_${STEAM_APP_ID}.acf`);
			let installDir = 'Slay the Spire 2';
			let branch = '';
			let buildId = '';
			try {
				const manifest = getKey(parseVdf(fs.readFileSync(manifestFile, 'utf8')), 'AppState') || {};
				installDir = getKey(manifest, 'installdir') || installDir;
				buildId = getKey(manifest, 'buildid') || '';
				branch = getKey(getKey(manifest, 'UserConfig'), 'BetaKey') || getKey(getKey(manifest, 'MountedConfig'), 'BetaKey') || '';
			} catch (error) {
				// 没有 appmanifest 也尝试默认目录名。
			}
			const gameDir = path.join(library, 'steamapps', 'common', installDir);
			if (fs.existsSync(path.join(gameDir, GAME_EXE)) || fs.existsSync(path.join(gameDir, 'SlayTheSpire2.pck'))) {
				installs.push({ gameDir, source: 'steam', steamBranch: branch || 'public', buildId });
			}
		}
	}
	return installs;
}

function sha256File(file) {
	return new Promise((resolve, reject) => {
		const hash = crypto.createHash('sha256');
		const stream = fs.createReadStream(file);
		stream.on('error', reject);
		stream.on('data', chunk => hash.update(chunk));
		stream.on('end', () => resolve(hash.digest('hex')));
	});
}

async function cachedSha(file) {
	const stat = fs.statSync(file);
	const key = `${file}|${stat.size}|${stat.mtimeMs}`;
	if (!shaCache.has(key)) {
		shaCache.set(key, await sha256File(file));
	}
	return shaCache.get(key);
}

/** 检查一个游戏目录：必需文件、release_info 版本与 sts2.dll SHA-256。 */
async function inspectGameDir(gameDir) {
	const result = { gameDir, exists: fs.existsSync(gameDir), ready: false, missing: [], version: '', commit: '', branch: '', dllSha256: '', modsDir: path.join(gameDir, 'mods') };
	if (!result.exists) {
		result.missing = REQUIRED_FILES.slice();
		return result;
	}
	result.missing = REQUIRED_FILES.filter(name => !fs.existsSync(path.join(gameDir, name)));
	result.ready = result.missing.length === 0;
	try {
		const info = JSON.parse(fs.readFileSync(path.join(gameDir, 'release_info.json'), 'utf8'));
		result.version = String(info.version || '');
		result.commit = String(info.commit || '');
		result.branch = String(info.branch || '');
	} catch (error) {
		// 缺 release_info 已记录在 missing。
	}
	const dll = path.join(gameDir, DATA_DIR, 'sts2.dll');
	if (fs.existsSync(dll)) {
		try {
			result.dllSha256 = await cachedSha(dll);
		} catch (error) {
			result.dllSha256 = '';
		}
	}
	return result;
}

/** 按启动器设置拼出游戏命令行；日志参数与 Android GodotApp 相同。 */
function buildLaunchArgs(settings, profile) {
	const args = [];
	if (settings.windowMode === 'fullscreen') {
		args.push('--fullscreen');
	} else if (settings.windowMode === 'windowed') {
		args.push('--windowed');
	}
	if (settings.renderer !== 'default') {
		args.push('--rendering-driver', settings.renderer);
	}
	if (settings.logLevel !== 'off') {
		const level = settings.logLevel === 'very_debug' ? 'VeryDebug' : settings.logLevel === 'debug' ? 'Debug' : 'Info';
		for (const type of LOG_TYPES) {
			args.push('-log', type, level);
		}
	}
	if (!profile || !profile.launchViaSteam) {
		args.push('--force-steam', 'off');
	}
	args.push(...splitArgs(settings.extraArgs), ...splitArgs(profile && profile.extraArgs));
	return args;
}

/** 按空白拆分参数，支持双引号包住带空格的值。 */
function splitArgs(text) {
	const args = [];
	if (!text) {
		return args;
	}
	const pattern = /"([^"]*)"|(\S+)/g;
	let match;
	while ((match = pattern.exec(text)) !== null) {
		args.push(match[1] !== undefined ? match[1] : match[2]);
	}
	return args;
}

/**
 * 启动游戏。默认直接运行 exe 并关闭游戏内 Steam 平台初始化；
 * 用户主动选择 Steam 启动时通过 steam://run 保留平台功能。
 */
function launchGame(profile, settings, openExternal) {
	const args = buildLaunchArgs(settings, profile);
	if (profile.launchViaSteam) {
		const encoded = args.map(arg => (/\s/.test(arg) ? `"${arg}"` : arg)).join(' ');
		const url = args.length ? `steam://run/${STEAM_APP_ID}//${encodeURIComponent(encoded)}/` : `steam://rungameid/${STEAM_APP_ID}`;
		return openExternal(url).then(() => ({ via: 'steam', args, child: null }));
	}
	const exe = path.join(profile.gameDir, GAME_EXE);
	if (!fs.existsSync(exe)) {
		return Promise.reject(new Error(`${GAME_EXE} not found`));
	}
	return new Promise((resolve, reject) => {
		const child = spawn(exe, args, { cwd: profile.gameDir, detached: true, stdio: 'ignore', windowsHide: false });
		child.once('error', reject);
		child.once('spawn', () => {
			child.unref();
			resolve({ via: 'exe', args, child });
		});
	});
}

module.exports = {
	STEAM_APP_ID,
	GAME_EXE,
	REQUIRED_FILES,
	detectSteamInstalls,
	inspectGameDir,
	buildLaunchArgs,
	splitArgs,
	launchGame,
};
