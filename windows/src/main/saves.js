'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { extractZip, zipDirectory } = require('./ziputil');

const SNAPSHOT_SCHEMA = 1;

/** PC 版存档根目录（Godot user://）：%APPDATA%\SlayTheSpire2。 */
function defaultSaveRoot() {
	const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
	return path.join(appData, 'SlayTheSpire2');
}

function resolveSaveRoot(settings) {
	return settings.saveRoot ? path.resolve(settings.saveRoot) : defaultSaveRoot();
}

/** 账号目录 = 含 settings.save 的目录（如 steam/<SteamID64>、default/1），最多向下找三层。 */
function listAccounts(saveRoot) {
	const accounts = [];
	const walk = (dir, depth) => {
		let entries;
		try {
			entries = fs.readdirSync(dir, { withFileTypes: true });
		} catch (error) {
			return;
		}
		if (entries.some(e => e.isFile() && e.name === 'settings.save')) {
			const stat = fs.statSync(path.join(dir, 'settings.save'));
			accounts.push({ id: path.relative(saveRoot, dir).split(path.sep).join('/') || '.', path: dir, mtimeMs: stat.mtimeMs });
			return;
		}
		if (depth >= 3) {
			return;
		}
		for (const entry of entries) {
			if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'logs' && entry.name !== 'shader_cache') {
				walk(path.join(dir, entry.name), depth + 1);
			}
		}
	};
	walk(saveRoot, 0);
	accounts.sort((a, b) => b.mtimeMs - a.mtimeMs);
	return accounts;
}

function selectedAccount(settings) {
	const root = resolveSaveRoot(settings);
	const accounts = listAccounts(root);
	const chosen = accounts.find(a => a.id === settings.saveAccount) || accounts[0] || null;
	return { root, accounts, account: chosen };
}

function settingsFile(account) {
	return account ? path.join(account.path, 'settings.save') : null;
}

function readSettingsSave(account) {
	const file = settingsFile(account);
	if (!file || !fs.existsSync(file)) {
		return null;
	}
	return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/** 原子写回 settings.save；第一次修改前留一份 .launcher-backup。 */
function writeSettingsSave(account, json) {
	const file = settingsFile(account);
	if (!file) {
		throw new Error('no save account');
	}
	const backup = `${file}.launcher-backup`;
	if (fs.existsSync(file) && !fs.existsSync(backup)) {
		fs.copyFileSync(file, backup);
	}
	const temp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(temp, JSON.stringify(json, null, 2), 'utf8');
	fs.renameSync(temp, file);
}

function accountKey(account) {
	return account.id.replace(/[^a-zA-Z0-9._-]+/g, '_');
}

function snapshotDir(dataDir, account) {
	return path.join(dataDir, 'save-snapshots', accountKey(account));
}

function listSnapshots(dataDir, account) {
	if (!account) {
		return [];
	}
	const dir = snapshotDir(dataDir, account);
	let names = [];
	try {
		names = fs.readdirSync(dir).filter(name => name.endsWith('.zip'));
	} catch (error) {
		return [];
	}
	return names.map(name => {
		const stat = fs.statSync(path.join(dir, name));
		const match = /^\d{8}-\d{6}(?:-\d+)?-(.+)\.zip$/.exec(name);
		return { name, path: path.join(dir, name), size: stat.size, mtimeMs: stat.mtimeMs, reason: match ? match[1] : 'manual' };
	}).sort((a, b) => b.mtimeMs - a.mtimeMs);
}

function timestamp(date = new Date()) {
	const pad = n => String(n).padStart(2, '0');
	return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

async function createSnapshot(dataDir, account, reason, keep) {
	if (!account) {
		throw new Error('no save account');
	}
	const dir = snapshotDir(dataDir, account);
	fs.mkdirSync(dir, { recursive: true });
	let file = path.join(dir, `${timestamp()}-${reason}.zip`);
	for (let n = 1; fs.existsSync(file); n++) {
		file = path.join(dir, `${timestamp()}-${n}-${reason}.zip`);
	}
	await zipDirectory(account.path, file, { schema: SNAPSHOT_SCHEMA, account: account.id, reason, createdAt: new Date().toISOString() });
	pruneSnapshots(dataDir, account, keep);
	return file;
}

/** 只裁剪自动快照，保留最近 keep 个；手动快照不自动删除。 */
function pruneSnapshots(dataDir, account, keep) {
	const automatic = listSnapshots(dataDir, account).filter(s => s.reason !== 'manual');
	for (const snapshot of automatic.slice(Math.max(1, keep))) {
		fs.rmSync(snapshot.path, { force: true });
	}
}

/**
 * 恢复快照：先给当前存档做 before-restore 快照，解压到 staging 校验清单，再整目录替换并保留回滚。
 * staging 放在启动器数据目录；回滚目录放在账号目录旁。
 */
async function restoreSnapshot(dataDir, account, snapshotPath, keep) {
	const dir = snapshotDir(dataDir, account);
	if (path.dirname(path.resolve(snapshotPath)) !== path.resolve(dir)) {
		throw new Error('snapshot does not belong to this account');
	}
	const work = path.join(dataDir, 'restore-work', `${Date.now()}`);
	const staging = path.join(work, 'staging');
	fs.mkdirSync(staging, { recursive: true });
	try {
		await extractZip(snapshotPath, staging);
		const manifest = JSON.parse(fs.readFileSync(path.join(staging, 'snapshot.json'), 'utf8'));
		if (manifest.schema !== SNAPSHOT_SCHEMA || !Array.isArray(manifest.files)) {
			throw new Error('unsupported snapshot');
		}
		for (const file of manifest.files) {
			if (!fs.existsSync(path.join(staging, 'files', file))) {
				throw new Error(`snapshot is missing ${file}`);
			}
		}
		await createSnapshot(dataDir, account, 'before-restore', keep + 1);
		// 回滚目录放在账号目录旁（同盘，rename 不会跨盘失败）；以点开头，账号扫描会跳过。
		const rollback = path.join(path.dirname(account.path), `.${path.basename(account.path)}.launcher-rollback-${Date.now()}`);
		const restored = path.join(staging, 'files');
		if (!fs.existsSync(restored)) {
			fs.mkdirSync(restored);
		}
		fs.renameSync(account.path, rollback);
		try {
			moveDirectory(restored, account.path);
		} catch (error) {
			fs.rmSync(account.path, { recursive: true, force: true });
			fs.renameSync(rollback, account.path);
			throw error;
		}
		fs.rmSync(rollback, { recursive: true, force: true });
		fs.rmSync(work, { recursive: true, force: true });
	} catch (error) {
		fs.rmSync(work, { recursive: true, force: true });
		throw error;
	}
}

/** rename 跨盘会失败（数据目录与存档在不同盘时），退回复制。 */
function moveDirectory(from, to) {
	try {
		fs.renameSync(from, to);
	} catch (error) {
		if (error.code !== 'EXDEV') {
			throw error;
		}
		fs.cpSync(from, to, { recursive: true });
		fs.rmSync(from, { recursive: true, force: true });
	}
}

module.exports = {
	defaultSaveRoot,
	resolveSaveRoot,
	listAccounts,
	selectedAccount,
	readSettingsSave,
	writeSettingsSave,
	listSnapshots,
	createSnapshot,
	restoreSnapshot,
};
