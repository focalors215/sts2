'use strict';

/*
 * 崩溃与异常退出（规范 §5.4，对齐 Android StartupHealthTracker / Sts2CrashActivity）：
 * - 启动游戏前写 launch-marker.json（时间、版本、启动配置、MOD 列表、进程号），游戏正常退出时删除；
 *   启动器看到非零退出码时立即记一份崩溃报告；下次打开启动器发现残留标记也记一份。
 * - 启动器自身：启动时写 launcher-session.json，正常退出时删除；下次打开发现残留 = 上次启动器异常退出。
 * 崩溃报告放在 <数据目录>/crash-reports/*.json（最多保留 20 份），日志页可以查看 / 导出。
 */
const fs = require('fs');
const path = require('path');

const MARKER = 'launch-marker.json';
const SESSION = 'launcher-session.json';
const REPORT_DIR = 'crash-reports';
const ACK_FILE = 'acknowledged.json';
const KEEP_REPORTS = 20;

function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, 'utf8'));
	} catch (error) {
		return null; // 不存在或已损坏都按“没有”处理，调用方会记日志。
	}
}

function writeJson(file, value) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const temp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(temp, JSON.stringify(value, null, 2), 'utf8');
	fs.renameSync(temp, file);
}

function isAlive(pid) {
	if (!Number.isInteger(pid) || pid <= 0) {
		return false;
	}
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === 'EPERM';
	}
}

function writeLaunchMarker(dataDir, info) {
	const marker = { ...info, startedAt: new Date().toISOString() };
	writeJson(path.join(dataDir, MARKER), marker);
	return marker;
}

function readLaunchMarker(dataDir) {
	return readJson(path.join(dataDir, MARKER));
}

function updateLaunchMarker(dataDir, patch) {
	const marker = readLaunchMarker(dataDir);
	if (marker) {
		writeJson(path.join(dataDir, MARKER), { ...marker, ...patch });
	}
}

function clearLaunchMarker(dataDir) {
	fs.rmSync(path.join(dataDir, MARKER), { force: true });
}

function reportStamp(date = new Date()) {
	const pad = n => String(n).padStart(2, '0');
	return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

/** 写一份崩溃报告；kind 为 game / launcher。返回报告。 */
function recordCrash(dataDir, kind, details) {
	const dir = path.join(dataDir, REPORT_DIR);
	const report = { kind, detectedAt: new Date().toISOString(), ...details };
	let file = path.join(dir, `${reportStamp()}-${kind}.json`);
	for (let n = 1; fs.existsSync(file); n++) {
		file = path.join(dir, `${reportStamp()}-${n}-${kind}.json`);
	}
	writeJson(file, report);
	const reports = listCrashReports(dataDir);
	for (const old of reports.slice(KEEP_REPORTS)) {
		fs.rmSync(old.path, { force: true });
	}
	return { ...report, name: path.basename(file), path: file };
}

function listCrashReports(dataDir) {
	const dir = path.join(dataDir, REPORT_DIR);
	let names = [];
	try {
		names = fs.readdirSync(dir).filter(name => name.endsWith('.json') && name !== ACK_FILE);
	} catch (error) {
		return [];
	}
	return names.sort().reverse().map(name => ({ name, path: path.join(dir, name), ...(readJson(path.join(dir, name)) || {}) }));
}

/** 还没在界面上提示过的崩溃报告（每份只提示一次）。 */
function unacknowledgedReports(dataDir) {
	const ack = readJson(path.join(dataDir, REPORT_DIR, ACK_FILE)) || {};
	const seen = new Set(Array.isArray(ack.names) ? ack.names : []);
	return listCrashReports(dataDir).filter(report => !seen.has(report.name));
}

function acknowledgeReports(dataDir, names) {
	const file = path.join(dataDir, REPORT_DIR, ACK_FILE);
	const ack = readJson(file) || {};
	const seen = new Set(Array.isArray(ack.names) ? ack.names : []);
	names.forEach(name => seen.add(name));
	const existing = new Set(listCrashReports(dataDir).map(report => report.name));
	writeJson(file, { names: [...seen].filter(name => existing.has(name)) });
}

/**
 * 启动器打开时检查上次留下的标记。返回 { gameStillRunning, reports }：
 * - 启动器会话残留 → 记一份 launcher 报告；
 * - 游戏标记残留且进程还在 → 游戏仍在运行（启动器中途被关掉），保留标记；
 * - 游戏标记残留、进程已不在：启动器当时正常退出（launcherClosed）则无法得知退出码，只清标记；
 *   否则启动器没机会记录游戏退出（启动器自己崩了或被结束），按异常退出记一份 game 报告。
 */
function checkPreviousRun(dataDir, { now = Date.now(), alive = isAlive } = {}) {
	const reports = [];
	const session = readJson(path.join(dataDir, SESSION));
	if (session) {
		reports.push(recordCrash(dataDir, 'launcher', { reason: 'session_not_closed', session }));
	}
	const marker = readLaunchMarker(dataDir);
	let gameStillRunning = null;
	let clearedUnknown = null;
	if (marker) {
		if (marker.pid && alive(marker.pid)) {
			gameStillRunning = marker;
		} else if (marker.launcherClosed) {
			clearedUnknown = marker;
			clearLaunchMarker(dataDir);
		} else {
			reports.push(recordCrash(dataDir, 'game', { reason: 'marker_left', marker, ageSeconds: Math.round((now - Date.parse(marker.startedAt || 0)) / 1000) }));
			clearLaunchMarker(dataDir);
		}
	}
	return { gameStillRunning, clearedUnknown, reports };
}

function startSession(dataDir, info) {
	writeJson(path.join(dataDir, SESSION), { ...info, pid: process.pid, startedAt: new Date().toISOString() });
}

function endSession(dataDir) {
	fs.rmSync(path.join(dataDir, SESSION), { force: true });
}

module.exports = {
	MARKER,
	SESSION,
	isAlive,
	writeLaunchMarker,
	readLaunchMarker,
	updateLaunchMarker,
	clearLaunchMarker,
	recordCrash,
	listCrashReports,
	unacknowledgedReports,
	acknowledgeReports,
	checkPreviousRun,
	startSession,
	endSession,
};
