'use strict';

/*
 * WebDAV 云存档（对齐 Android webdav/WebDavSyncManager、WebDavSavePathMapper）：
 * - 远端目录：<用户配置的 WebDAV 地址>/SlayTheSpire2/saves/<槽位>/，槽位留空用启动配置 ID；
 *   .sts2re/manifest.json 记录每个文件的 SHA-1（远端没有哈希时下载后计算）。
 * - 只同步白名单存档：profile.save、profileN/saves/{progress,prefs,current_run,current_run_mp}.save(.backup)、
 *   profileN/saves/history/*.run，以及 modded/ 下的同名文件；settings.save 只在用户开启实验开关时同步。不做远端删除镜像。
 * - baseline 只记录本地与远端内容相同（双方都确认过）的文件，作为三方比较的共同祖先：
 *   拉取时本地改过且远端也改过 → 冲突；上传时同理；用户选择保留哪一份后用 force 覆盖。
 * - 拉取前先把账号目录打包备份到 <数据目录>/webdav/cloud/<槽位>/backups/；下载先进 staging 并校验 SHA-1。
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { log } = require('./logger');
const { zipDirectory } = require('./ziputil');

const REMOTE_ROOT_DIR = 'SlayTheSpire2/saves';
const REMOTE_MANIFEST = '.sts2re/manifest.json';
const MAX_PROPFIND_DEPTH = 8;
const REQUEST_TIMEOUT_MS = 60000;
const CLOUD_MODES = ['off', 'manual', 'pull_on_launch', 'full_auto'];
const KEEP_BACKUPS = 10;

class CloudConflictError extends Error {
	constructor(paths) {
		super('cloud_conflict');
		this.conflicts = paths;
	}
}

function normalizeRelative(value) {
	let text = String(value || '').trim().replace(/\\/g, '/');
	text = text.replace(/^\/+/, '').replace(/\/{2,}/g, '/');
	return text;
}

/** 与 Android isSupportedLocalPath 相同的白名单。 */
function isSupportedPath(relative, includeSettingsSave) {
	const value = normalizeRelative(relative);
	if (!value || value.includes(':')) return false;
	if (value.split('/').some(part => !part || part === '.' || part === '..')) return false;
	const lower = value.toLowerCase();
	if (lower === 'profile.save' || lower === 'modded/profile.save') return true;
	if (lower === 'settings.save') return !!includeSettingsSave;
	return isProfileSavePath(lower, '') || isProfileSavePath(lower, 'modded/');
}

function isProfileSavePath(lower, prefix) {
	for (let slot = 1; slot <= 3; slot++) {
		const base = `${prefix}profile${slot}/saves/`;
		const names = ['progress.save', 'prefs.save', 'current_run.save', 'current_run.save.backup', 'current_run_mp.save', 'current_run_mp.save.backup'];
		if (names.some(name => lower === base + name)) return true;
		const history = `${base}history/`;
		if (lower.startsWith(history) && lower.endsWith('.run') && lower.length > history.length + 4 && !lower.slice(history.length).includes('/')) return true;
	}
	return false;
}

function sanitizeId(value) {
	return String(value || '').trim().toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^[-.]+|[-.]+$/g, '') || 'default';
}

function sha1File(file) {
	return crypto.createHash('sha1').update(fs.readFileSync(file)).digest('hex');
}

function resolveInside(root, relative) {
	const target = path.resolve(root, normalizeRelative(relative));
	const base = path.resolve(root);
	if (target !== base && !target.startsWith(base + path.sep)) {
		throw new Error(`WebDAV path escapes account root: ${relative}`);
	}
	return target;
}

// ---------- WebDAV 客户端 ----------

function encodePath(relative) {
	return normalizeRelative(relative).split('/').filter(Boolean).map(encodeURIComponent).join('/');
}

class WebDavClient {
	constructor({ url, username, password }, fetchImpl = fetch) {
		let base;
		try {
			base = new URL(String(url || '').trim());
		} catch (error) {
			throw new Error('webdav_bad_url');
		}
		if (!/^https?:$/.test(base.protocol) || base.username || base.password || base.search || base.hash) {
			throw new Error('webdav_bad_url');
		}
		if (!base.pathname.endsWith('/')) base.pathname += '/';
		this.base = base;
		this.auth = username || password ? `Basic ${Buffer.from(`${username || ''}:${password || ''}`, 'utf8').toString('base64')}` : '';
		this.fetch = fetchImpl;
	}

	url(relative, directory) {
		const encoded = encodePath(relative);
		return new URL(encoded + (directory && encoded ? '/' : ''), this.base).toString();
	}

	async request(method, relative, { body, headers = {}, directory = false, ok = [200, 201, 204, 207] } = {}) {
		const init = { method, headers: { ...headers }, redirect: 'follow', signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) };
		if (this.auth) init.headers.Authorization = this.auth;
		if (body !== undefined) init.body = body;
		let response;
		try {
			response = await this.fetch(this.url(relative, directory), init);
		} catch (error) {
			const wrapped = new Error('webdav_network');
			wrapped.cause = error;
			throw wrapped;
		}
		if (!ok.includes(response.status)) {
			const error = new Error(response.status === 401 || response.status === 403 ? 'webdav_auth' : `webdav_http_${response.status}`);
			error.status = response.status;
			error.method = method;
			throw error;
		}
		return response;
	}

	async exists(relative, directory) {
		try {
			await this.request('PROPFIND', relative, { directory, headers: { Depth: '0', 'Content-Type': 'application/xml; charset=utf-8' }, body: '<?xml version="1.0" encoding="utf-8" ?><propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>' });
			return true;
		} catch (error) {
			if (error.status === 404) return false;
			throw error;
		}
	}

	/** 逐级 MKCOL（已存在返回 405 也算成功）。 */
	async ensureDirectory(relative) {
		const parts = normalizeRelative(relative).split('/').filter(Boolean);
		for (let i = 1; i <= parts.length; i++) {
			const dir = parts.slice(0, i).join('/');
			if (await this.exists(dir, true)) continue;
			await this.request('MKCOL', dir, { directory: true, ok: [200, 201, 204, 405] });
		}
	}

	/** 递归列出目录下的文件：[{ relativePath, size, lastModifiedMs, etag }]（相对 dir）。 */
	async listFiles(dir) {
		const out = [];
		const visit = async (current, depth) => {
			if (depth > MAX_PROPFIND_DEPTH) return;
			const response = await this.request('PROPFIND', current, {
				directory: true,
				headers: { Depth: '1', 'Content-Type': 'application/xml; charset=utf-8' },
				body: '<?xml version="1.0" encoding="utf-8" ?><propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><getlastmodified/><getetag/></prop></propfind>',
			});
			const entries = parseMultistatus(await response.text(), this.base.pathname);
			const self = normalizeRelative(current);
			for (const entry of entries) {
				if (normalizeRelative(entry.path) === self || !entry.path.startsWith(self ? `${self}/` : '')) continue;
				if (entry.collection) {
					await visit(entry.path, depth + 1);
				} else {
					out.push({ ...entry, relativePath: normalizeRelative(entry.path).slice(normalizeRelative(dir).length).replace(/^\//, '') });
				}
			}
		};
		await visit(dir, 0);
		return out;
	}

	async readBytes(relative) {
		try {
			const response = await this.request('GET', relative, { ok: [200] });
			return Buffer.from(await response.arrayBuffer());
		} catch (error) {
			if (error.status === 404) return null;
			throw error;
		}
	}

	async download(relative, file) {
		const response = await this.request('GET', relative, { ok: [200] });
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, Buffer.from(await response.arrayBuffer()));
	}

	async upload(relative, data) {
		const parent = normalizeRelative(relative).split('/').slice(0, -1).join('/');
		if (parent) await this.ensureDirectory(parent);
		await this.request('PUT', relative, { body: data, headers: { 'Content-Type': 'application/octet-stream' }, ok: [200, 201, 204] });
	}
}

/** 解析 PROPFIND 207 Multi-Status（命名空间前缀不固定）。path 为相对 basePath 的解码路径。 */
function parseMultistatus(xml, basePath) {
	const tag = name => new RegExp(`<(?:[\\w-]+:)?${name}\\b[^>]*>([\\s\\S]*?)</(?:[\\w-]+:)?${name}>`, 'i');
	const entries = [];
	for (const match of String(xml).matchAll(/<(?:[\w-]+:)?response\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?response>/gi)) {
		const block = match[1];
		const hrefMatch = tag('href').exec(block);
		if (!hrefMatch) continue;
		let href = hrefMatch[1].trim().replace(/&amp;/g, '&');
		try {
			href = new URL(href, 'http://placeholder').pathname;
		} catch (error) {
			continue;
		}
		let decoded;
		try {
			decoded = decodeURIComponent(href);
		} catch (error) {
			decoded = href;
		}
		let base = basePath || '/';
		try {
			base = decodeURIComponent(base);
		} catch (error) {
			// 保持原样。
		}
		if (!decoded.startsWith(base)) continue;
		const relative = normalizeRelative(decoded.slice(base.length)).replace(/\/$/, '');
		const collection = /<(?:[\w-]+:)?collection\b/i.test(block);
		const length = tag('getcontentlength').exec(block);
		const modified = tag('getlastmodified').exec(block);
		const etag = tag('getetag').exec(block);
		entries.push({
			path: relative,
			collection,
			size: length ? Number(length[1].trim()) : -1,
			lastModifiedMs: modified ? Date.parse(modified[1].trim()) || 0 : 0,
			etag: etag ? etag[1].trim().replace(/&quot;/g, '"') : '',
		});
	}
	return entries;
}

// ---------- 同步计划（纯函数，便于测试） ----------

function baselineByPath(baseline) {
	const map = new Map();
	for (const entry of (baseline && Array.isArray(baseline.entries)) ? baseline.entries : []) {
		const key = String(entry.local_relative_path || '').toLowerCase();
		// 旧版本记录过双方不一致的观察，那不是共同祖先。
		if (key && entry.local_sha1 && String(entry.local_sha1).toLowerCase() === String(entry.remote_sha1 || '').toLowerCase()) {
			map.set(key, entry);
		}
	}
	return map;
}

function sameContent(local, remote) {
	return !!(local && remote && local.sha1 && remote.sha1 && local.sha1.toLowerCase() === remote.sha1.toLowerCase() && (remote.size < 0 || local.size === remote.size));
}

function planDownloads(remoteEntries, localEntries, baseline, force) {
	const locals = new Map(localEntries.map(entry => [entry.path.toLowerCase(), entry]));
	const bases = baselineByPath(baseline);
	const conflicts = [];
	const downloads = [];
	for (const remote of remoteEntries) {
		const key = remote.path.toLowerCase();
		const local = locals.get(key);
		if (sameContent(local, remote)) continue;
		const base = bases.get(key);
		const localChanged = !!local && (!base || local.sha1.toLowerCase() !== String(base.local_sha1).toLowerCase());
		const remoteChanged = !base || remote.sha1.toLowerCase() !== String(base.remote_sha1).toLowerCase();
		if (!force && localChanged) {
			if (remoteChanged) conflicts.push(remote.path);
			continue;
		}
		downloads.push(remote);
	}
	if (conflicts.length) throw new CloudConflictError(conflicts);
	return downloads;
}

function planUploads(localEntries, remoteEntries, baseline, force) {
	const remotes = new Map(remoteEntries.map(entry => [entry.path.toLowerCase(), entry]));
	const bases = baselineByPath(baseline);
	const conflicts = [];
	const uploads = [];
	for (const local of localEntries) {
		const key = local.path.toLowerCase();
		const remote = remotes.get(key);
		const base = bases.get(key);
		if (sameContent(local, remote)) continue;
		const localChanged = !base || local.sha1.toLowerCase() !== String(base.local_sha1).toLowerCase();
		let remoteChanged;
		if (!base) remoteChanged = !!remote && remote.sha1.toLowerCase() !== local.sha1.toLowerCase();
		else if (!remote) remoteChanged = !!base.remote_sha1;
		else remoteChanged = remote.sha1.toLowerCase() !== String(base.remote_sha1).toLowerCase();
		if (!force && localChanged && remoteChanged) {
			conflicts.push(local.path);
			continue;
		}
		if (force ? (!remote || local.sha1.toLowerCase() !== remote.sha1.toLowerCase()) : (localChanged || !remote)) {
			uploads.push(local);
		}
	}
	if (conflicts.length) throw new CloudConflictError(conflicts);
	return uploads;
}

/** 新 baseline：保留旧的共同祖先，再加上这次确认双方相同的文件。 */
function nextBaseline(previous, localEntries, remoteEntries) {
	const agreed = baselineByPath(previous);
	const remotes = new Map(remoteEntries.map(entry => [entry.path.toLowerCase(), entry]));
	for (const local of localEntries) {
		const remote = remotes.get(local.path.toLowerCase());
		if (sameContent(local, remote)) {
			agreed.set(local.path.toLowerCase(), { local_relative_path: local.path, local_sha1: local.sha1, size: local.size, remote_sha1: remote.sha1, remote_timestamp_ms: remote.lastModifiedMs || 0 });
		}
	}
	return { schema: 1, provider: 'webdav', synced_at_ms: Date.now(), entries: [...agreed.values()] };
}

function collectLocal(accountDir, includeSettingsSave) {
	const out = [];
	const walk = dir => {
		let entries;
		try {
			entries = fs.readdirSync(dir, { withFileTypes: true });
		} catch (error) {
			if (error.code !== 'ENOENT') log().w('cloud', `读取存档目录失败: ${dir}`, error);
			return;
		}
		for (const entry of entries) {
			const full = path.join(dir, entry.name);
			if (entry.isSymbolicLink()) continue;
			if (entry.isDirectory()) {
				walk(full);
			} else if (entry.isFile()) {
				const relative = path.relative(accountDir, full).split(path.sep).join('/');
				if (isSupportedPath(relative, includeSettingsSave)) {
					const stat = fs.statSync(full);
					out.push({ path: relative, file: full, size: stat.size, sha1: sha1File(full) });
				}
			}
		}
	};
	walk(accountDir);
	return out.sort((a, b) => a.path.localeCompare(b.path));
}

// ---------- 同步管理 ----------

class WebDavSync {
	/** options：{ config: {url, username, password, slot, includeSettingsSave}, accountDir, stateDir, profileId } */
	constructor(options, fetchImpl = fetch) {
		this.config = options.config;
		this.accountDir = options.accountDir;
		this.slot = sanitizeId(options.config.slot || options.profileId || 'global');
		this.stateDir = path.join(options.stateDir, this.slot);
		this.client = new WebDavClient(options.config, fetchImpl);
		this.remoteDir = `${REMOTE_ROOT_DIR}/${this.slot}`;
	}

	readState(name) {
		try {
			return JSON.parse(fs.readFileSync(path.join(this.stateDir, name), 'utf8'));
		} catch (error) {
			if (error.code !== 'ENOENT') log().w('cloud', `读取 WebDAV 状态 ${name} 失败`, error);
			return null;
		}
	}

	writeState(name, value) {
		fs.mkdirSync(this.stateDir, { recursive: true });
		const file = path.join(this.stateDir, name);
		fs.writeFileSync(`${file}.tmp`, JSON.stringify(value, null, 2), 'utf8');
		fs.renameSync(`${file}.tmp`, file);
	}

	status() {
		const manifest = this.readState('manifest.json');
		return { slot: this.slot, remoteDir: this.remoteDir, remoteFiles: manifest && Array.isArray(manifest.remote_entries) ? manifest.remote_entries.length : 0, hasBaseline: !!this.readState('baseline.json') };
	}

	async testConnection() {
		await this.client.ensureDirectory(this.remoteDir);
		return this.remoteDir;
	}

	async readRemoteManifest() {
		try {
			const bytes = await this.client.readBytes(`${this.remoteDir}/${REMOTE_MANIFEST}`);
			if (!bytes) return new Map();
			const root = JSON.parse(bytes.toString('utf8'));
			const map = new Map();
			for (const entry of Array.isArray(root.entries) ? root.entries : []) {
				if (isSupportedPath(entry.local_relative_path, this.config.includeSettingsSave)) {
					map.set(entry.local_relative_path.toLowerCase(), entry);
				}
			}
			return map;
		} catch (error) {
			log().w('cloud', '读取远端 manifest 失败（改为下载计算哈希）', error);
			return new Map();
		}
	}

	/** 远端白名单文件，带 SHA-1（manifest 的大小 / etag 与当前一致时直接采用，否则下载计算）。 */
	async listRemote() {
		await this.client.ensureDirectory(this.remoteDir);
		const manifest = await this.readRemoteManifest();
		const files = await this.client.listFiles(this.remoteDir);
		const seen = new Set();
		const out = [];
		for (const file of files) {
			const relative = normalizeRelative(file.relativePath);
			if (!isSupportedPath(relative, this.config.includeSettingsSave) || seen.has(relative.toLowerCase())) continue;
			seen.add(relative.toLowerCase());
			const known = manifest.get(relative.toLowerCase());
			const matches = known && known.sha1 && (known.size < 0 || file.size < 0 || Number(known.size) === file.size) && (!known.etag || !file.etag || known.etag === file.etag);
			out.push({ path: relative, size: file.size, lastModifiedMs: file.lastModifiedMs, etag: file.etag, sha1: matches ? known.sha1 : '' });
		}
		const staging = fs.mkdtempSync(path.join(this.ensureStateDir(), 'hash-'));
		try {
			for (const entry of out.filter(e => !e.sha1)) {
				const file = resolveInside(staging, entry.path);
				await this.client.download(`${this.remoteDir}/${entry.path}`, file);
				entry.sha1 = sha1File(file);
			}
		} finally {
			fs.rmSync(staging, { recursive: true, force: true });
		}
		return out.sort((a, b) => a.path.localeCompare(b.path));
	}

	ensureStateDir() {
		fs.mkdirSync(this.stateDir, { recursive: true });
		return this.stateDir;
	}

	async writeManifests(remoteEntries) {
		this.writeState('manifest.json', { schema: 1, provider: 'webdav', remote_slot: this.slot, account_root: this.accountDir, fetched_at_ms: Date.now(), remote_entries: remoteEntries });
		const entries = remoteEntries.map(e => ({ local_relative_path: e.path, remote_path: `${this.remoteDir}/${e.path}`, size: e.size, updated_at_ms: e.lastModifiedMs, etag: e.etag, sha1: e.sha1 }));
		await this.client.upload(`${this.remoteDir}/${REMOTE_MANIFEST}`, Buffer.from(JSON.stringify({ schema: 1, provider: 'webdav', remote_slot: this.slot, written_at_ms: Date.now(), entries }, null, 2), 'utf8'));
	}

	async refresh() {
		const remote = await this.listRemote();
		await this.writeManifests(remote);
		return { remoteFiles: remote.length };
	}

	async backupLocal() {
		const dir = path.join(this.ensureStateDir(), 'backups');
		fs.mkdirSync(dir, { recursive: true });
		const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
		const file = path.join(dir, `sts2-webdav-pull-backup-${stamp}.zip`);
		await zipDirectory(this.accountDir, file, { schema: 1, reason: 'webdav-pull', account: this.accountDir, createdAt: new Date().toISOString() });
		const backups = fs.readdirSync(dir).filter(name => name.endsWith('.zip')).sort().reverse();
		for (const old of backups.slice(KEEP_BACKUPS)) fs.rmSync(path.join(dir, old), { force: true });
		return file;
	}

	/** 拉取：返回 { downloaded, preserved, backup }；冲突抛 CloudConflictError。 */
	async pull(force = false, onProgress = () => {}) {
		onProgress(5, '列出远端文件…');
		const remote = await this.listRemote();
		const localBefore = collectLocal(this.accountDir, this.config.includeSettingsSave);
		const baseline = this.readState('baseline.json');
		const downloads = planDownloads(remote, localBefore, baseline, force);
		if (!downloads.length) {
			await this.writeManifests(remote);
			this.writeState('baseline.json', nextBaseline(baseline, localBefore, remote));
			return { downloaded: 0, preserved: remote.length, backup: '' };
		}
		const backup = await this.backupLocal();
		const staging = fs.mkdtempSync(path.join(this.ensureStateDir(), 'pull-'));
		try {
			for (let i = 0; i < downloads.length; i++) {
				const entry = downloads[i];
				onProgress(10 + Math.round(i * 70 / downloads.length), `下载 ${i + 1}/${downloads.length}: ${entry.path}`);
				const out = resolveInside(staging, entry.path);
				await this.client.download(`${this.remoteDir}/${entry.path}`, out);
				if (entry.sha1 && sha1File(out).toLowerCase() !== entry.sha1.toLowerCase()) {
					throw new Error(`WebDAV download SHA-1 mismatch for ${entry.path}`);
				}
			}
			for (const entry of downloads) {
				const target = resolveInside(this.accountDir, entry.path);
				fs.mkdirSync(path.dirname(target), { recursive: true });
				const temp = `${target}.webdav-${process.pid}.tmp`;
				fs.copyFileSync(resolveInside(staging, entry.path), temp);
				fs.renameSync(temp, target);
			}
		} finally {
			fs.rmSync(staging, { recursive: true, force: true });
		}
		const localAfter = collectLocal(this.accountDir, this.config.includeSettingsSave);
		await this.writeManifests(remote);
		this.writeState('baseline.json', nextBaseline(baseline, localAfter, remote));
		return { downloaded: downloads.length, preserved: remote.length - downloads.length, backup: path.basename(backup) };
	}

	/** 上传：返回 { uploaded }；冲突抛 CloudConflictError。 */
	async push(force = false, onProgress = () => {}) {
		onProgress(5, '列出远端文件…');
		const remote = await this.listRemote();
		const local = collectLocal(this.accountDir, this.config.includeSettingsSave);
		const baseline = this.readState('baseline.json');
		const uploads = planUploads(local, remote, baseline, force);
		for (let i = 0; i < uploads.length; i++) {
			onProgress(15 + Math.round(i * 70 / uploads.length), `上传 ${i + 1}/${uploads.length}: ${uploads[i].path}`);
			await this.client.upload(`${this.remoteDir}/${uploads[i].path}`, fs.readFileSync(uploads[i].file));
		}
		const merged = new Map(remote.map(entry => [entry.path.toLowerCase(), entry]));
		for (const entry of uploads) {
			merged.set(entry.path.toLowerCase(), { path: entry.path, size: entry.size, lastModifiedMs: Date.now(), etag: '', sha1: entry.sha1 });
		}
		const refreshed = [...merged.values()].sort((a, b) => a.path.localeCompare(b.path));
		await this.writeManifests(refreshed);
		this.writeState('baseline.json', nextBaseline(baseline, local, refreshed));
		return { uploaded: uploads.length };
	}
}

function normalizeCloudMode(mode) {
	return CLOUD_MODES.includes(mode) ? mode : 'manual';
}

module.exports = {
	CLOUD_MODES,
	CloudConflictError,
	isSupportedPath,
	sanitizeId,
	parseMultistatus,
	planDownloads,
	planUploads,
	nextBaseline,
	collectLocal,
	WebDavClient,
	WebDavSync,
	normalizeCloudMode,
};
