'use strict';

/*
 * Nexus Mods 商店（对齐 Android NexusModsApiClient / NexusModsStoreActivity）：
 * 用户手动保存 Personal API Key（本机加密）后浏览热门 / 最新 / 近期更新、按 URL / 数字 ID 查询、
 * 列出文件并下载 ZIP，导入当前游戏目录的 mods/（复用本地导入的冲突确认）。
 * 非 Premium 账号的下载接口会被拒绝：引导用户在网页「Mod Manager Download」拿到 nxm:// 链接后粘贴，
 * 用链接里的 key / expires 请求下载地址。
 */
const fs = require('fs');
const path = require('path');
const { log } = require('./logger');

const API_V1 = 'https://api.nexusmods.com/v1';
const API_V3 = 'https://api.nexusmods.com/v3';
const GAME_DOMAIN = 'slaythespire2';
const TIMEOUT_MS = 25000;
const MAX_UPDATED_DETAILS = 20;
const MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024;

class NexusApiError extends Error {
	constructor(status, message) {
		super(message);
		this.status = status;
	}
}

function first(...values) {
	for (const value of values) {
		if (value !== undefined && value !== null && String(value).trim() !== '') return String(value).trim();
	}
	return '';
}

/** 数字 ID 或 nexusmods.com/<游戏>/mods/<ID> 链接 → ID。 */
function parseModId(text) {
	const value = String(text || '').trim();
	if (/^\d+$/.test(value)) return value;
	const match = /nexusmods\.com\/([^/]+)\/mods\/(\d+)/i.exec(value);
	return match ? match[2] : '';
}

/** nxm://<游戏>/mods/<ID>/files/<文件 ID>?key=…&expires=… */
function parseNxmLink(text) {
	const match = /nxm:\/\/([^/]+)\/mods\/(\d+)\/files\/(\d+)(?:\?(\S+))?/i.exec(String(text || '').trim());
	if (!match) return null;
	const query = new URLSearchParams(match[4] || '');
	const token = { gameDomain: match[1].toLowerCase(), modId: match[2], fileId: match[3], key: query.get('key') || '', expires: query.get('expires') || '' };
	return token.key && token.expires ? token : null;
}

function parseMod(object) {
	const modId = first(object.mod_id, object.game_scoped_id, object.id, object.uid);
	return {
		modId,
		name: first(object.name, object.title) || '未知 MOD',
		summary: first(object.summary, object.short_description),
		description: first(object.description, object.desc),
		author: first(object.author, object.uploaded_by, object.user && object.user.name),
		version: first(object.version),
		category: first(object.category_name, object.category),
		pictureUrl: first(object.picture_url),
		pageUrl: first(object.mod_page_uri, object.mod_page_url) || (modId ? `https://www.nexusmods.com/${GAME_DOMAIN}/mods/${modId}` : ''),
		downloads: Number(first(object.mod_downloads, object.downloads, object.unique_downloads)) || 0,
		updated: Number(first(object.updated_timestamp)) || Date.parse(first(object.updated_time, object.updated_at)) / 1000 || 0,
		adult: object.contains_adult_content === true,
		available: object.available !== false,
	};
}

function categoryPriority(category) {
	const value = String(category || '').toLowerCase();
	if (value.includes('main')) return 0;
	if (value.includes('update')) return 1;
	if (value.includes('optional')) return 2;
	if (value.includes('misc')) return 3;
	return 4;
}

function parseFiles(value) {
	const array = Array.isArray(value) ? value : (value && (value.files || value.data)) || [];
	return array.map(object => {
		const category = first(object.category_name, object.category);
		const bytes = object.size_in_bytes !== undefined ? Number(object.size_in_bytes) : object.size_kb !== undefined ? Number(object.size_kb) * 1024 : Number(object.size) || 0;
		return {
			fileId: first(object.file_id, object.id, object.game_scoped_id),
			name: first(object.name, object.file_name) || '未知文件',
			fileName: first(object.file_name),
			version: first(object.version),
			category,
			description: first(object.description),
			size: bytes,
			uploaded: Number(object.uploaded_timestamp) || 0,
			primary: object.is_primary === true || category.toLowerCase() === 'main',
		};
	}).filter(file => file.fileId).sort((a, b) => (a.primary === b.primary ? 0 : a.primary ? -1 : 1)
		|| categoryPriority(a.category) - categoryPriority(b.category) || a.name.localeCompare(b.name));
}

function parseDownloadLinks(value) {
	let array = Array.isArray(value) ? value : value && (value.data || value.links);
	if (!array && value && (value.URI || value.uri)) array = [value];
	return (array || []).map(object => ({ name: first(object.name, object.short_name) || 'Nexus', uri: first(object.URI, object.uri, object.url) })).filter(link => /^https:\/\//i.test(link.uri));
}

function errorMessage(status, body) {
	let detail = '';
	try {
		detail = first(JSON.parse(body).message, JSON.parse(body).error);
	} catch (error) {
		detail = '';
	}
	if (status === 401) return 'nexus_bad_key';
	if (status === 403) return 'nexus_premium_required';
	if (status === 404) return 'nexus_not_found';
	if (status === 429) return 'nexus_rate_limited';
	return `Nexus Mods API HTTP ${status}${detail ? `: ${detail}` : ''}`;
}

class NexusClient {
	constructor(apiKey, { version = '0', fetchImpl = fetch } = {}) {
		this.apiKey = String(apiKey || '').trim();
		this.version = version;
		this.fetch = fetchImpl;
	}

	headers(authenticated) {
		const headers = { Accept: 'application/json', 'User-Agent': `STS2CottageLauncher/${this.version} Windows`, 'Application-Name': 'STS2CottageLauncher', 'Application-Version': this.version };
		if (authenticated) {
			if (!this.apiKey) throw new Error('nexus_no_key');
			headers.apikey = this.apiKey;
		}
		return headers;
	}

	async json(url, authenticated = true) {
		let response;
		try {
			response = await this.fetch(url, { headers: this.headers(authenticated), signal: AbortSignal.timeout(TIMEOUT_MS) });
		} catch (error) {
			if (error.message === 'nexus_no_key') throw error;
			const wrapped = new Error('nexus_network');
			wrapped.cause = error;
			throw wrapped;
		}
		const body = await response.text();
		if (!response.ok) {
			throw new NexusApiError(response.status, errorMessage(response.status, body));
		}
		return body ? JSON.parse(body) : {};
	}

	validate() {
		return this.json(`${API_V1}/users/validate.json`).then(user => ({ name: first(user.name, user.username, user.user_id), premium: user.is_premium === true }));
	}

	async feed(name) {
		const value = await this.json(`${API_V1}/games/${GAME_DOMAIN}/mods/${name}.json`);
		return (Array.isArray(value) ? value : []).map(parseMod).filter(mod => mod.modId);
	}

	async trendingV3() {
		const value = await this.json(`${API_V3}/games/${GAME_DOMAIN}/trending-mods`, false);
		const mods = value && value.data && Array.isArray(value.data.mods) ? value.data.mods : [];
		return mods.map(object => ({ ...parseMod(object), modId: parseModId(object.mod_page_url) }));
	}

	/** 热门 + 最新 + 最近更新合并去重（同 Android discoverMods）。 */
	async discover() {
		const merged = new Map();
		const add = list => list.forEach(mod => {
			const key = mod.modId || mod.pageUrl || mod.name;
			if (key && !merged.has(key)) merged.set(key, mod);
		});
		for (const name of ['trending', 'latest_added', 'latest_updated']) {
			try {
				add(await this.feed(name));
			} catch (error) {
				if (['nexus_bad_key', 'nexus_no_key'].includes(error.message)) throw error;
				log().w('nexus', `读取 Nexus 列表 ${name} 失败`, error);
			}
		}
		if (!merged.size) add(await this.trendingV3());
		return [...merged.values()];
	}

	getMod(modId) {
		return this.json(`${API_V1}/games/${GAME_DOMAIN}/mods/${encodeURIComponent(modId)}.json`).then(parseMod);
	}

	/** URL / 数字 ID 精确查询；其他文字在发现列表 + 最近一个月更新里按名称过滤。 */
	async search(query) {
		const id = parseModId(query);
		if (id) return [await this.getMod(id)];
		const merged = new Map((await this.discover()).map(mod => [mod.modId, mod]));
		try {
			const updated = await this.json(`${API_V1}/games/${GAME_DOMAIN}/mods/updated.json?period=1m`);
			for (const entry of (Array.isArray(updated) ? updated : []).slice(0, MAX_UPDATED_DETAILS)) {
				const modId = first(entry.mod_id, entry.id);
				if (modId && !merged.has(modId)) {
					try {
						merged.set(modId, await this.getMod(modId));
					} catch (error) {
						log().d('nexus', `读取近期更新 MOD ${modId} 失败`, error);
					}
				}
			}
		} catch (error) {
			log().w('nexus', '读取 Nexus 近期更新列表失败', error);
		}
		const needle = String(query || '').trim().toLowerCase();
		const all = [...merged.values()];
		return needle ? all.filter(mod => [mod.name, mod.summary, mod.author, mod.category].join('\n').toLowerCase().includes(needle)) : all;
	}

	files(modId) {
		return this.json(`${API_V1}/games/${GAME_DOMAIN}/mods/${encodeURIComponent(modId)}/files.json`).then(parseFiles);
	}

	downloadLinks(modId, fileId, nxm) {
		let url = `${API_V1}/games/${GAME_DOMAIN}/mods/${encodeURIComponent(modId)}/files/${encodeURIComponent(fileId)}/download_link.json`;
		if (nxm && nxm.key && nxm.expires) {
			url += `?key=${encodeURIComponent(nxm.key)}&expires=${encodeURIComponent(nxm.expires)}`;
		}
		return this.json(url).then(parseDownloadLinks);
	}

	/** 下载到 dir，文件名取 Content-Disposition / URL / 回退名。 */
	async download(uri, dir, fallbackName, onProgress = () => {}) {
		let response;
		try {
			response = await this.fetch(uri, { headers: { 'User-Agent': `STS2CottageLauncher/${this.version} Windows` }, signal: AbortSignal.timeout(30 * 60 * 1000) });
		} catch (error) {
			const wrapped = new Error('nexus_network');
			wrapped.cause = error;
			throw wrapped;
		}
		if (!response.ok) throw new NexusApiError(response.status, `HTTP ${response.status} while downloading MOD file.`);
		const disposition = response.headers.get('content-disposition') || '';
		const fromHeader = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(disposition);
		let name = first(fromHeader && decodeURIComponent(fromHeader[1]), decodeURIComponent(new URL(uri).pathname.split('/').pop() || ''), fallbackName, 'nexus_mod_download.zip');
		name = path.basename(name).replace(/[\\/:*?"<>|\u0000-\u001f]+/g, '_') || 'nexus_mod_download.zip';
		fs.mkdirSync(dir, { recursive: true });
		const file = path.join(dir, name);
		const total = Number(response.headers.get('content-length')) || 0;
		const fd = fs.openSync(`${file}.part`, 'w');
		let received = 0;
		try {
			const reader = response.body.getReader();
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				received += value.length;
				if (received > MAX_DOWNLOAD_BYTES) {
					reader.cancel().catch(error => log().d('nexus', '取消超大下载失败', error));
					throw new Error('nexus_too_large');
				}
				fs.writeSync(fd, value);
				onProgress(received, total);
			}
		} finally {
			fs.closeSync(fd);
		}
		fs.renameSync(`${file}.part`, file);
		return file;
	}
}

module.exports = { GAME_DOMAIN, NexusClient, NexusApiError, parseModId, parseNxmLink, parseMod, parseFiles, parseDownloadLinks };
