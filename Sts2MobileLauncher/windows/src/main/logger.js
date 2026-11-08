'use strict';

/*
 * 启动器日志（三端统一规范 doc/architecture/cross-platform-parity.md §5.1）：
 *   2026-11-09T12:34:56.789+08:00 E [online] 创建房间失败: <原文> | <异常类型>: <消息>
 *       at ...（堆栈，多行缩进）
 * 滚动文件 launcher.log，单文件上限 2 MiB，另保留 launcher.1.log … launcher.4.log（共 5 个）。
 * 所有写入都先脱敏：注册过的密钥原文（frp 令牌、WebDAV 密码、Nexus / AI key、Steam 凭据）
 * 以及常见的 token=… / "password": "…" / Authorization 头 / URL 里的账号密码。
 */
const fs = require('fs');
const path = require('path');

const LEVELS = ['D', 'I', 'W', 'E'];
const TAGS = new Set(['app', 'launch', 'online', 'frp', 'mods', 'saves', 'cloud', 'workshop', 'nexus', 'update', 'ui']);
const DEFAULT_MAX_BYTES = 2 * 1024 * 1024;
const DEFAULT_KEEP = 5;
const MASK = '***';

const SECRET_PATTERNS = [
	// "token": "…"、"apiKey": "…"、'password': '…'
	[/(["']?(?:auth\.)?(?:token|password|passwd|pwd|secret|api[_-]?key|apikey|refresh[_-]?token|access[_-]?token|authorization)["']?\s*[:=]\s*)(["'])(?:\\.|(?!\2).)*\2/gi, `$1$2${MASK}$2`],
	// token=abc、password: abc（未加引号）
	[/(\b(?:auth\.)?(?:token|password|passwd|pwd|secret|api[_-]?key|apikey|refresh[_-]?token|access[_-]?token)\b\s*[:=]\s*)(?!["'*])[^\s,;&"'}]+/gi, `$1${MASK}`],
	// Authorization: Bearer xxx / Basic xxx
	[/(\bauthorization\b["']?\s*[:=]\s*["']?(?:bearer|basic|token)\s+)[A-Za-z0-9._~+/=-]+/gi, `$1${MASK}`],
	[/(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}/gi, `$1${MASK}`],
	// https://user:pass@host
	[/(\b[a-z][a-z0-9+.-]*:\/\/)([^\s:/@]+):([^\s@/]+)@/gi, `$1$2:${MASK}@`],
];

function pad(value, width = 2) {
	return String(value).padStart(width, '0');
}

/** 本地时间 ISO 8601，带毫秒与时区偏移。 */
function localTimestamp(date = new Date()) {
	const offset = -date.getTimezoneOffset();
	const sign = offset >= 0 ? '+' : '-';
	const abs = Math.abs(offset);
	return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

function escapeRegExp(text) {
	return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 脱敏：先替换已登记的密钥原文，再按模式遮盖。 */
function redact(text, secrets = []) {
	let out = String(text === undefined || text === null ? '' : text);
	for (const secret of secrets) {
		if (secret && secret.length >= 4) {
			out = out.replace(new RegExp(escapeRegExp(secret), 'g'), MASK);
		}
	}
	for (const [pattern, replacement] of SECRET_PATTERNS) {
		out = out.replace(pattern, replacement);
	}
	return out;
}

function describeError(error) {
	if (error === undefined || error === null) {
		return '';
	}
	if (error instanceof Error || (typeof error === 'object' && (error.stack || error.message))) {
		const type = error.name || (error.constructor && error.constructor.name) || 'Error';
		const message = error.message !== undefined ? error.message : String(error);
		const code = error.code ? ` [${error.code}]` : '';
		let stack = typeof error.stack === 'string' ? error.stack.split('\n').filter(line => /^\s+at /.test(line)) : [];
		const cause = error.cause ? describeError(error.cause) : null;
		const lines = [`${type}${code}: ${message}`];
		stack = stack.map(line => `    ${line.trim()}`);
		return { head: lines[0], stack: cause ? [...stack, `    Caused by: ${cause.head}`, ...cause.stack] : stack };
	}
	return { head: `${typeof error}: ${String(error)}`, stack: [] };
}

/** 一条日志行（含可选的异常与堆栈）。 */
function formatLine(level, tag, message, error, date) {
	const lvl = LEVELS.includes(level) ? level : 'I';
	const safeTag = TAGS.has(tag) ? tag : 'app';
	let text = `${localTimestamp(date)} ${lvl} [${safeTag}] ${String(message === undefined ? '' : message).replace(/\r?\n/g, '\n    ')}`;
	const described = describeError(error);
	if (described) {
		text += ` | ${described.head}`;
		if (described.stack.length) {
			text += `\n${described.stack.join('\n')}`;
		}
	}
	return `${text}\n`;
}

class Logger {
	constructor({ dir, name = 'launcher', maxBytes = DEFAULT_MAX_BYTES, keep = DEFAULT_KEEP, debug = false, mirror = null } = {}) {
		this.dir = dir;
		this.name = name;
		this.maxBytes = maxBytes;
		this.keep = Math.max(1, keep);
		this.debug = debug;
		this.mirror = mirror;
		this.secrets = new Set();
	}

	get file() {
		return path.join(this.dir, `${this.name}.log`);
	}

	/** 所有日志文件，最新在前（launcher.log、launcher.1.log …）。 */
	files() {
		const list = [this.file];
		for (let i = 1; i < this.keep; i++) {
			list.push(path.join(this.dir, `${this.name}.${i}.log`));
		}
		return list.filter(file => fs.existsSync(file));
	}

	setDebug(enabled) {
		this.debug = !!enabled;
	}

	addSecret(value) {
		if (typeof value === 'string' && value.trim().length >= 4) {
			this.secrets.add(value.trim());
			if (value !== value.trim()) {
				this.secrets.add(value);
			}
		}
	}

	removeSecret(value) {
		if (typeof value === 'string') {
			this.secrets.delete(value);
			this.secrets.delete(value.trim());
		}
	}

	redact(text) {
		return redact(text, [...this.secrets].sort((a, b) => b.length - a.length));
	}

	rotate() {
		for (let i = this.keep - 1; i >= 1; i--) {
			const from = i === 1 ? this.file : path.join(this.dir, `${this.name}.${i - 1}.log`);
			const to = path.join(this.dir, `${this.name}.${i}.log`);
			if (fs.existsSync(from)) {
				fs.rmSync(to, { force: true });
				fs.renameSync(from, to);
			}
		}
	}

	write(level, tag, message, error) {
		if (level === 'D' && !this.debug) {
			return '';
		}
		const line = this.redact(formatLine(level, tag, message, error));
		try {
			fs.mkdirSync(this.dir, { recursive: true });
			let size = 0;
			try {
				size = fs.statSync(this.file).size;
			} catch (statError) {
				size = 0; // 文件还不存在。
			}
			if (size > 0 && size + Buffer.byteLength(line) > this.maxBytes) {
				this.rotate();
			}
			fs.appendFileSync(this.file, line, 'utf8');
		} catch (writeError) {
			// 日志目录不可写时只能退回控制台，不能再写日志。
			process.stderr.write(`[launcher-log] ${writeError.message}\n`);
		}
		if (this.mirror) {
			this.mirror(line);
		}
		return line;
	}

	d(tag, message, error) { return this.write('D', tag, message, error); }
	i(tag, message, error) { return this.write('I', tag, message, error); }
	w(tag, message, error) { return this.write('W', tag, message, error); }
	e(tag, message, error) { return this.write('E', tag, message, error); }
}

/** 解析一行日志的级别与标签（日志页过滤用）；不是本格式的行返回 null。 */
function parseLine(line) {
	const match = /^(\d{4}-\d{2}-\d{2}T[\d:.]+[+-]\d{2}:\d{2}) ([DIWE]) \[([a-z]+)\] (.*)$/.exec(line);
	return match ? { time: match[1], level: match[2], tag: match[3], message: match[4] } : null;
}

// 进程内共享的启动器日志；主进程启动时 setShared()，单元测试里未设置时写到空日志。
const nullLogger = { d() {}, i() {}, w() {}, e() {}, write() {}, setDebug() {}, addSecret() {}, removeSecret() {}, redact: text => redact(text), files: () => [] };
let shared = null;

function setShared(logger) {
	shared = logger;
}

function log() {
	return shared || nullLogger;
}

module.exports = { Logger, LEVELS, TAGS, redact, formatLine, localTimestamp, parseLine, describeError, setShared, log };
