'use strict';

/*
 * 日志页与「导出日志」（规范 §5.5，对齐 Android LogViewerActivity / RuntimeLogFiles）：
 * 列出启动器日志、游戏日志（最近几次）、联机组件日志、frp 日志与崩溃记录；读取尾部并按级别分类；
 * 打包 sts2-logs-windows-<yyyyMMdd-HHmmss>.zip（日志 + diagnostics.json + 脱敏后的启动器配置）。
 */
const fs = require('fs');
const path = require('path');
const yazl = require('yazl');

const KINDS = ['launcher', 'game', 'online', 'frp', 'crash'];
const GAME_LOG_KEEP = 6;
const DEFAULT_TAIL_BYTES = 1024 * 1024;
const MAX_VIEW_LINES = 20000;
const EXPORT_FILE_LIMIT = 16 * 1024 * 1024;

function statFile(file) {
	try {
		const stat = fs.statSync(file);
		return stat.isFile() ? stat : null;
	} catch (error) {
		return null; // 文件不存在或刚被滚动删除。
	}
}

function listDir(dir, pattern) {
	try {
		return fs.readdirSync(dir).filter(name => pattern.test(name)).map(name => path.join(dir, name));
	} catch (error) {
		return []; // 目录还不存在。
	}
}

/**
 * 所有日志来源。roots：{ dataDir, saveRoot }。返回按类别、时间（新在前）排序的条目，
 * id 稳定（kind/文件名），渲染进程只能用 id 读取，不能传任意路径。
 */
function listLogSources({ dataDir, saveRoot }) {
	const groups = {
		launcher: listDir(path.join(dataDir, 'logs'), /^launcher(\.\d+)?\.log$/),
		game: saveRoot ? listDir(path.join(saveRoot, 'logs'), /\.log$/i) : [],
		online: saveRoot ? listDir(path.join(saveRoot, 'launcher'), /^online-game(\.\d+)?\.log$/) : [],
		frp: listDir(path.join(dataDir, 'frp'), /^frpc.*\.log$/),
		crash: listDir(path.join(dataDir, 'crash-reports'), /\.json$/),
	};
	const out = [];
	for (const kind of KINDS) {
		let entries = groups[kind]
			.map(file => ({ file, stat: statFile(file) }))
			.filter(entry => entry.stat)
			.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
		if (kind === 'game') {
			entries = entries.slice(0, GAME_LOG_KEEP);
		}
		for (const { file, stat } of entries) {
			out.push({ id: `${kind}/${path.basename(file)}`, kind, name: path.basename(file), path: file, size: stat.size, mtimeMs: stat.mtimeMs });
		}
	}
	return out;
}

function findSource(sources, id) {
	return sources.find(source => source.id === id) || null;
}

/** 按行判断级别：启动器统一格式直接读级别；游戏 / frp 日志按常见关键字推断。 */
function classifyLine(line) {
	const own = /^\d{4}-\d{2}-\d{2}T[\d:.]+[+-]\d{2}:\d{2} ([DIWE]) \[/.exec(line);
	if (own) {
		return own[1];
	}
	if (/^\s*\[?(?:ERROR|FATAL|CRITICAL|E)\]?[\s:]|\b(?:ERROR|FATAL|CRITICAL|EXCEPTION)\b|SCRIPT ERROR|USER ERROR|Unhandled exception|\[E\]|\w+Exception:/.test(line)) {
		return 'E';
	}
	if (/^\s*\[?(?:WARN|WARNING|W)\]?[\s:]|\bWARN(?:ING)?\b|\[W\]/.test(line)) {
		return 'W';
	}
	if (/\b(?:DEBUG|VERYDEBUG|VERY_DEBUG|TRACE)\b|\[D\]/.test(line)) {
		return 'D';
	}
	return 'I';
}

/** 读取文件尾部（默认 1 MiB），丢掉被截断的第一行；返回带级别的行（续行继承上一行级别）。 */
function readTail(file, maxBytes = DEFAULT_TAIL_BYTES) {
	const stat = fs.statSync(file);
	const start = Math.max(0, stat.size - maxBytes);
	const length = stat.size - start;
	const buffer = Buffer.alloc(length);
	const fd = fs.openSync(file, 'r');
	try {
		fs.readSync(fd, buffer, 0, length, start);
	} finally {
		fs.closeSync(fd);
	}
	let text = buffer.toString('utf8');
	if (start > 0) {
		const newline = text.indexOf('\n');
		text = newline >= 0 ? text.slice(newline + 1) : '';
	}
	let lines = text.replace(/\r\n/g, '\n').split('\n');
	if (lines.length && lines[lines.length - 1] === '') {
		lines.pop();
	}
	const truncatedLines = lines.length > MAX_VIEW_LINES;
	if (truncatedLines) {
		lines = lines.slice(-MAX_VIEW_LINES);
	}
	let previous = 'I';
	const rows = lines.map(line => {
		const continuation = /^\s+(?:at |Caused by:|\.\.\.)/.test(line) || (/^\s{4}/.test(line) && line.trim() !== '');
		const level = continuation ? previous : classifyLine(line);
		previous = level;
		return { level, text: line };
	});
	return { size: stat.size, truncated: start > 0 || truncatedLines, rows };
}

function exportName(date = new Date()) {
	const pad = n => String(n).padStart(2, '0');
	return `sts2-logs-windows-${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}.zip`;
}

const SECRET_KEY = /token|password|passwd|secret|api[_-]?key|apikey|credential|cookie|authorization/i;

/** 启动器配置的脱敏副本：键名像密钥的字段一律替换。 */
function redactConfig(value) {
	if (Array.isArray(value)) {
		return value.map(redactConfig);
	}
	if (value && typeof value === 'object') {
		const out = {};
		for (const [key, inner] of Object.entries(value)) {
			out[key] = SECRET_KEY.test(key) ? (inner ? '***' : inner) : redactConfig(inner);
		}
		return out;
	}
	return value;
}

/**
 * 打包日志 zip。每个文件先按 redact（启动器日志的脱敏函数）处理；单个文件超过 16 MiB 时只保留尾部。
 * 返回写入的条目名列表。
 */
function exportLogs(zipPath, { sources, diagnostics, config, redact = text => text }) {
	const entries = [];
	const part = `${zipPath}.part`;
	return new Promise((resolve, reject) => {
		const zip = new yazl.ZipFile();
		for (const source of sources) {
			const stat = statFile(source.path);
			if (!stat) {
				continue;
			}
			let buffer;
			try {
				if (stat.size > EXPORT_FILE_LIMIT) {
					const fd = fs.openSync(source.path, 'r');
					buffer = Buffer.alloc(EXPORT_FILE_LIMIT);
					try {
						fs.readSync(fd, buffer, 0, EXPORT_FILE_LIMIT, stat.size - EXPORT_FILE_LIMIT);
					} finally {
						fs.closeSync(fd);
					}
				} else {
					buffer = fs.readFileSync(source.path);
				}
			} catch (error) {
				diagnostics.exportErrors = [...(diagnostics.exportErrors || []), `${source.id}: ${error.message}`];
				continue;
			}
			const name = `logs/${source.kind}/${source.name}`;
			zip.addBuffer(Buffer.from(redact(buffer.toString('utf8')), 'utf8'), name, { mtime: new Date(stat.mtimeMs) });
			entries.push(name);
		}
		zip.addBuffer(Buffer.from(redact(JSON.stringify(diagnostics, null, 2)), 'utf8'), 'diagnostics.json');
		entries.push('diagnostics.json');
		if (config) {
			zip.addBuffer(Buffer.from(redact(JSON.stringify(redactConfig(config), null, 2)), 'utf8'), 'launcher-config.json');
			entries.push('launcher-config.json');
		}
		const out = fs.createWriteStream(part);
		out.on('error', reject);
		out.on('close', () => {
			try {
				fs.renameSync(part, zipPath);
				resolve(entries);
			} catch (error) {
				reject(error);
			}
		});
		zip.outputStream.on('error', reject);
		zip.outputStream.pipe(out);
		zip.end();
	});
}

module.exports = { KINDS, listLogSources, findSource, classifyLine, readTail, exportName, redactConfig, exportLogs };
