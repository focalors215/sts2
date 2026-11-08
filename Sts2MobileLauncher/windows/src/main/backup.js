'use strict';

/*
 * 整机数据备份（对齐 Android「完整应用数据备份」）：一个 zip 包含
 *   saves/…            游戏 user:// 目录（全部存档账号、游戏选项；跳过 logs/、shader_cache/、launcher/ 临时文件）
 *   launcher/launcher.json  启动器配置（含联机 playerId，换电脑续局需要带上，见规范 §3.4 第 7 条）
 *   mods/…             可选：当前游戏目录的 mods/
 *   backup.json        清单（schema、类型、时间、启动器版本、包含项）
 * 不包含 secrets.json（DPAPI 加密只在本机本用户可解，换电脑无效）与 FRP 令牌。
 * 恢复：先校验清单，自动把当前数据备份到 <数据目录>/full-backups/，存档目录整体替换（失败回滚），
 * 启动器设置合并恢复（保留本机的启动配置列表），MOD 按路径覆盖复制（不删除现有 MOD）。
 */
const fs = require('fs');
const path = require('path');
const yazl = require('yazl');
const { extractZip, listFiles } = require('./ziputil');
const { log } = require('./logger');

const KIND = 'sts2-windows-full-backup';
const SCHEMA = 1;
const SKIP_SAVE_DIRS = new Set(['logs', 'shader_cache', 'vulkan', 'launcher']);

function stamp(date = new Date()) {
	const pad = n => String(n).padStart(2, '0');
	return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function backupName(date) {
	return `sts2-full-backup-windows-${stamp(date)}.zip`;
}

function saveFiles(saveRoot) {
	if (!fs.existsSync(saveRoot)) return [];
	return listFiles(saveRoot).filter(relative => {
		const top = relative.split('/')[0];
		return !SKIP_SAVE_DIRS.has(top) && !/\.(tmp|part)$/i.test(relative) && !/\.launcher-rollback-/.test(relative);
	});
}

/** 统计备份大小（界面显示）。 */
function measure({ saveRoot, modsDir }) {
	const sum = (root, files) => files.reduce((total, file) => {
		try {
			return total + fs.statSync(path.join(root, file)).size;
		} catch (error) {
			return total; // 统计期间文件被删除。
		}
	}, 0);
	const saves = saveFiles(saveRoot);
	const mods = modsDir && fs.existsSync(modsDir) ? listFiles(modsDir) : [];
	return { saveFiles: saves.length, saveBytes: sum(saveRoot, saves), modFiles: mods.length, modBytes: sum(modsDir, mods) };
}

function createBackup(zipPath, { saveRoot, launcherConfig, modsDir, includeMods, launcherVersion }) {
	const saves = saveFiles(saveRoot);
	const mods = includeMods && modsDir && fs.existsSync(modsDir) ? listFiles(modsDir) : [];
	const manifest = { schema: SCHEMA, kind: KIND, createdAt: new Date().toISOString(), launcherVersion, includes: { saves: saves.length, launcherConfig: !!launcherConfig, mods: mods.length } };
	const part = `${zipPath}.part`;
	return new Promise((resolve, reject) => {
		const zip = new yazl.ZipFile();
		for (const file of saves) zip.addFile(path.join(saveRoot, file), `saves/${file}`);
		for (const file of mods) zip.addFile(path.join(modsDir, file), `mods/${file}`);
		if (launcherConfig) {
			zip.addBuffer(Buffer.from(JSON.stringify(launcherConfig, null, 2), 'utf8'), 'launcher/launcher.json');
		}
		zip.addBuffer(Buffer.from(JSON.stringify(manifest, null, 2), 'utf8'), 'backup.json');
		const out = fs.createWriteStream(part);
		out.on('error', reject);
		zip.outputStream.on('error', reject);
		out.on('close', () => {
			try {
				fs.renameSync(part, zipPath);
				resolve(manifest);
			} catch (error) {
				reject(error);
			}
		});
		zip.outputStream.pipe(out);
		zip.end();
	});
}

/** 解压并校验备份，返回 { manifest, root }（root 为解压目录，调用方负责删除）。 */
async function openBackup(zipPath, workDir) {
	fs.rmSync(workDir, { recursive: true, force: true });
	fs.mkdirSync(workDir, { recursive: true });
	try {
		await extractZip(zipPath, workDir);
	} catch (error) {
		fs.rmSync(workDir, { recursive: true, force: true });
		const wrapped = new Error('backup_invalid');
		wrapped.cause = error;
		throw wrapped;
	}
	let manifest = null;
	try {
		manifest = JSON.parse(fs.readFileSync(path.join(workDir, 'backup.json'), 'utf8'));
	} catch (error) {
		log().w('saves', '整机备份缺少有效的 backup.json', error);
	}
	if (!manifest || manifest.kind !== KIND || manifest.schema !== SCHEMA) {
		fs.rmSync(workDir, { recursive: true, force: true });
		throw new Error('backup_invalid');
	}
	return { manifest, root: workDir };
}

/** 把 from 目录整体替换到 to（先改名旧目录，失败回滚）。from 与 to 可能跨盘。 */
function replaceDirectory(from, to) {
	const rollback = `${to}.launcher-rollback-${Date.now()}`;
	const existed = fs.existsSync(to);
	if (existed) fs.renameSync(to, rollback);
	try {
		fs.mkdirSync(path.dirname(to), { recursive: true });
		fs.cpSync(from, to, { recursive: true });
	} catch (error) {
		fs.rmSync(to, { recursive: true, force: true });
		if (existed) fs.renameSync(rollback, to);
		throw error;
	}
	if (existed) fs.rmSync(rollback, { recursive: true, force: true });
}

/**
 * 恢复。保留存档目录里被跳过的 logs/ 等目录（从旧目录拷回）。返回 { savesRestored, launcherConfig, modsRestored }。
 * launcherConfig 是备份里的配置对象，由调用方合并进当前配置。
 */
function restoreBackup({ root, manifest }, { saveRoot, modsDir }) {
	const result = { savesRestored: 0, launcherConfig: null, modsRestored: 0, manifest };
	const savesDir = path.join(root, 'saves');
	if (fs.existsSync(savesDir)) {
		for (const keep of SKIP_SAVE_DIRS) {
			const existing = path.join(saveRoot, keep);
			if (fs.existsSync(existing) && !fs.existsSync(path.join(savesDir, keep))) {
				fs.cpSync(existing, path.join(savesDir, keep), { recursive: true });
			}
		}
		result.savesRestored = listFiles(savesDir).length;
		replaceDirectory(savesDir, saveRoot);
	}
	const configFile = path.join(root, 'launcher', 'launcher.json');
	if (fs.existsSync(configFile)) {
		result.launcherConfig = JSON.parse(fs.readFileSync(configFile, 'utf8'));
	}
	const backupMods = path.join(root, 'mods');
	if (modsDir && fs.existsSync(backupMods)) {
		fs.mkdirSync(modsDir, { recursive: true });
		fs.cpSync(backupMods, modsDir, { recursive: true, force: true });
		result.modsRestored = listFiles(backupMods).length;
	}
	return result;
}

module.exports = { KIND, backupName, measure, createBackup, openBackup, restoreBackup, saveFiles };
