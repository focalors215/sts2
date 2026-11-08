'use strict';

/*
 * Steam 创意工坊（对齐 Android SteamWorkshopCatalog / SteamWorkshopLibrary）：
 * - 浏览：匿名读取 Steam Community 公开 Workshop 页面（旧版 HTML 与新版 SSR 两种格式），再用
 *   ISteamRemoteStorage/GetPublishedFileDetails 补全大小、更新时间、预览图；排序 / 时间筛选同 Android。
 * - 详情：公开详情页的完整描述、截图与前置 MOD（RequiredItems）。
 * - 安装（PC 方式）：Steam 客户端订阅后会把条目下载到 <Steam 库>/steamapps/workshop/content/2868840/<id>/，
 *   启动器从这里复制到 <游戏目录>/mods/<id>/（走本地 MOD 导入的冲突确认）；条目带旧式直链 file_url 时也可直接下载。
 *   Android 的 SteamPipe UGC 匿名下载 / 尖塔补给站需要完整的 manifest/chunk 协议，Windows 端尚未实现。
 * - 已下载记录：<数据目录>/workshop/library.json，按 PublishedFileId 记录导入的 MOD ID、远端更新时间，用于检查更新。
 */
const fs = require('fs');
const path = require('path');
const { log } = require('./logger');

const APP_ID = '2868840';
const USER_AGENT = 'STS2CottageLauncher/1.0';
const SORTS = {
	trend: { browse: 'trend', actual: 'trend' },
	mostrecent: { browse: 'mostrecent', actual: 'mostrecent' },
	lastupdated: { browse: 'lastupdated', actual: 'lastupdated' },
	totaluniquesubscribers: { browse: 'totaluniquesubscribers', actual: 'totaluniquesubscribers' },
};
const DAYS = [7, 30, 90, 180, 365, -1];
const FETCH_TIMEOUT_MS = 25000;
const MAX_DIRECT_DOWNLOAD_BYTES = 1024 * 1024 * 1024;

const RE = {
	itemBlock: /<div\b[^>]*class="workshopItem"[^>]*>(.*?<div class="workshopItemAuthorName ellipsis">.*?<\/div>.*?)<\/div>/gis,
	legacyId: /(?:\?|&amp;|&)id=(\d+)/i,
	legacyAppId: /data-appid="(\d+)"/i,
	itemPreview: /class="workshopItemPreviewImage[^"]*"\s+src="([^"]+)"/is,
	itemTitle: /class="workshopItemTitle ellipsis">(.*?)<\/div>/is,
	itemAuthor: /class="workshopItemAuthorName ellipsis">.*?<a\b[^>]*>(.*?)<\/a>/is,
	hover: /SharedFileBindMouseHover\(\s*"sharedfile_(\d+)"\s*,\s*false\s*,\s*(\{.*?\})\s*\);/gs,
	ssrScript: /<script\b[^>]*\sid\s*=\s*(?:"valve-ssr-data"|'valve-ssr-data')[^>]*>(.*?)<\/script\s*>/is,
	ssrRender: /window\.SSR\.renderContext=JSON\.parse\("(.+?)"\);/s,
	description: /<div\b[^>]*class="workshopItemDescription"[^>]*id="highlightContent"[^>]*>(.*?)<\/div>/is,
	fullScreenshotBlock: /var\s+rgFullScreenshotURLs\s*=\s*\[(.*?)\];/is,
	fullScreenshotUrl: /['"]url['"]\s*:\s*['"]([^'"]+)['"]/gis,
	screenshotMapBlock: /var\s+rgScreenshotURLs\s*=\s*\{(.*?)\};/is,
	mappedScreenshotUrl: /['"]\d+['"]\s*:\s*['"]([^'"]+)['"]/gis,
	enlarged: /ShowEnlargedImagePreview\(\s*['"]([^'"]+)['"]/gis,
	previewImage: /<img\b[^>]*id="previewImage"[^>]*\bsrc="([^"]+)"/is,
	ogImage: /<meta\b[^>]*property="og:image"[^>]*content="([^"]+)"/is,
	requiredBlock: /<div\b[^>]*id="RequiredItems"[^>]*>(.*?)<\/div>\s*<\/div>/is,
	requiredLink: /<a\b[^>]*href="([^"]*filedetails\/\?[^"]*\bid=(\d+)[^"]*)"[^>]*>\s*<div\b[^>]*class="requiredItem"[^>]*>(.*?)<\/div>\s*<\/a>/gis,
};

function decodeHtml(text) {
	return String(text || '')
		.replace(/&#x([0-9a-f]+);/gi, (m, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
		.replace(/&#(\d+);/g, (m, dec) => String.fromCodePoint(Number.parseInt(dec, 10)))
		.replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ')
		.replace(/&amp;/g, '&');
}

function stripTags(html) {
	return decodeHtml(String(html || '').replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, ' ')).replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').trim();
}

/** 从输入里取 PublishedFileId：纯数字或带 ?id= 的 Workshop / Steam 链接。 */
function parseWorkshopRef(text) {
	const value = String(text || '').trim();
	if (/^\d{4,20}$/.test(value)) {
		return value;
	}
	const match = /[?&]id=(\d{4,20})/.exec(value) || /\/filedetails\/(\d{4,20})/.exec(value);
	return match ? match[1] : '';
}

function browseUrl({ query = '', page = 1, pageSize = 30, sort = 'trend', days = 7 }) {
	const option = SORTS[sort] || SORTS.trend;
	const url = new URL('https://steamcommunity.com/workshop/browse/');
	url.searchParams.set('appid', APP_ID);
	url.searchParams.set('searchtext', String(query).trim());
	url.searchParams.set('childpublishedfileid', '0');
	url.searchParams.set('l', 'schinese');
	url.searchParams.set('browsesort', option.browse);
	url.searchParams.set('section', 'readytouseitems');
	url.searchParams.set('actualsort', option.actual);
	url.searchParams.set('p', String(Math.max(1, page)));
	url.searchParams.set('numperpage', String(Math.min(50, Math.max(1, pageSize))));
	url.searchParams.set('days', String(DAYS.includes(Number(days)) ? Number(days) : 7));
	return url.toString();
}

function emptyItem(id) {
	return { id, appId: APP_ID, title: `Workshop ${id}`, author: '', description: '', previewUrl: '', size: 0, subscriptions: 0, views: 0, timeUpdated: 0, fileUrl: '' };
}

/** 解析公开浏览页：先试旧版 HTML 列表，再试 SSR 数据。返回 { items, hasNext, total }。 */
function parseBrowsePage(html, page = 1) {
	const descriptions = new Map();
	for (const match of html.matchAll(RE.hover)) {
		try {
			descriptions.set(match[1], stripTags(JSON.parse(match[2]).description || ''));
		} catch (error) {
			log().d('workshop', `浏览页悬浮描述解析失败: ${match[1]}`, error);
		}
	}
	const items = [];
	for (const match of html.matchAll(RE.itemBlock)) {
		const block = match[1];
		const idMatch = RE.legacyId.exec(block);
		if (!idMatch) continue;
		const item = emptyItem(idMatch[1]);
		const appId = RE.legacyAppId.exec(block);
		if (appId) item.appId = appId[1];
		const preview = RE.itemPreview.exec(block);
		if (preview) item.previewUrl = decodeHtml(preview[1]);
		const title = RE.itemTitle.exec(block);
		if (title && stripTags(title[1])) item.title = stripTags(title[1]);
		const author = RE.itemAuthor.exec(block);
		if (author) item.author = stripTags(author[1]);
		item.description = descriptions.get(item.id) || '';
		items.push(item);
	}
	const hasNext = html.includes(`&p=${page + 1}`) && html.includes('pagebtn');
	if (items.length || hasNext) {
		return { items, hasNext, total: 0 };
	}
	return parseSsrPage(html, page) || { items: [], hasNext: false, total: 0 };
}

function parseSsrPage(html, page) {
	let context = null;
	const script = RE.ssrScript.exec(html);
	try {
		if (script) {
			context = JSON.parse(script[1]).renderContext;
		} else {
			const render = RE.ssrRender.exec(html);
			if (render) {
				context = JSON.parse(JSON.parse(`"${render[1]}"`));
			}
		}
	} catch (error) {
		log().d('workshop', '浏览页 SSR 数据解析失败', error);
		return null;
	}
	if (!context || !context.queryData) return null;
	let queries;
	try {
		queries = JSON.parse(context.queryData).queries || [];
	} catch (error) {
		log().d('workshop', '浏览页 queryData 解析失败', error);
		return null;
	}
	const names = new Map();
	for (const query of queries) {
		if (Array.isArray(query.queryKey) && query.queryKey[0] === 'PlayerLinkDetails') {
			const persona = query.state && query.state.data && query.state.data.public_data && query.state.data.public_data.persona_name;
			if (persona) names.set(String(query.queryKey[1]), persona);
		}
	}
	for (const query of queries) {
		const data = query.state && query.state.data;
		if (!data || !Array.isArray(data.results) || data.current_page === undefined || data.total_pages === undefined) continue;
		const current = Math.max(1, Number(data.current_page) || page);
		const items = data.results.filter(r => r && r.publishedfileid).map(r => ({
			...emptyItem(String(r.publishedfileid)),
			appId: String(r.consumer_appid || APP_ID),
			title: r.title || `Workshop ${r.publishedfileid}`,
			author: names.get(String(r.creator)) || '',
			description: stripTags(r.short_description || ''),
			previewUrl: r.preview_url || '',
			size: Number(r.file_size) || 0,
			subscriptions: Number(r.subscriptions) || 0,
			views: Number(r.views) || 0,
			timeUpdated: Number(r.time_updated) || 0,
		}));
		return { items, hasNext: current < Number(data.total_pages), total: Number(data.total_count) || 0 };
	}
	return null;
}

/** GetPublishedFileDetails 的单条结果 → 条目；result != 1（不存在 / 已隐藏）返回 null。 */
function parseDetail(raw) {
	if (!raw || Number(raw.result) !== 1 || !raw.publishedfileid) return null;
	return {
		...emptyItem(String(raw.publishedfileid)),
		appId: String(raw.consumer_app_id || raw.creator_app_id || APP_ID),
		title: raw.title || `Workshop ${raw.publishedfileid}`,
		description: stripTags(raw.description || ''),
		previewUrl: raw.preview_url || '',
		size: Number(raw.file_size) || 0,
		subscriptions: Number(raw.subscriptions) || 0,
		views: Number(raw.views) || 0,
		timeUpdated: Number(raw.time_updated) || 0,
		fileUrl: raw.file_url || '',
		fileName: raw.filename || '',
		creator: String(raw.creator || ''),
		tags: Array.isArray(raw.tags) ? raw.tags.map(t => t && t.tag).filter(Boolean) : [],
	};
}

/** 详情页：完整描述、截图、前置 MOD。 */
function parseCommunityDetail(html) {
	const description = RE.description.exec(html);
	const urls = [];
	const add = raw => {
		const url = normalizeImageUrl(raw);
		if (url && !urls.includes(url)) urls.push(url);
	};
	const full = RE.fullScreenshotBlock.exec(html);
	if (full) for (const match of full[1].matchAll(RE.fullScreenshotUrl)) add(match[1]);
	if (!urls.length) {
		const map = RE.screenshotMapBlock.exec(html);
		if (map) for (const match of map[1].matchAll(RE.mappedScreenshotUrl)) add(match[1]);
	}
	if (!urls.length) for (const match of html.matchAll(RE.enlarged)) add(match[1]);
	if (!urls.length) {
		const preview = RE.previewImage.exec(html) || RE.ogImage.exec(html);
		if (preview) add(preview[1]);
	}
	const required = [];
	const block = RE.requiredBlock.exec(html);
	if (block) {
		for (const match of block[1].matchAll(RE.requiredLink)) {
			if (!required.some(r => r.id === match[2])) {
				required.push({ id: match[2], title: stripTags(match[3]) || `Workshop ${match[2]}` });
			}
		}
	}
	return { description: description ? stripTags(description[1]) : '', screenshots: urls, required };
}

function normalizeImageUrl(raw) {
	let url = decodeHtml(String(raw || '')).replace(/\\\//g, '/').trim();
	if (url.startsWith('//')) url = `https:${url}`;
	if (!/^https?:\/\//i.test(url)) return '';
	if (!/(steamusercontent|steamuserimages|steamstatic|akamai)/i.test(url)) return '';
	return url.replace(/^http:/i, 'https:');
}

async function fetchText(url, init = {}, fetchImpl = fetch) {
	const response = await fetchImpl(url, {
		...init,
		headers: { 'User-Agent': USER_AGENT, 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8', ...(init.headers || {}) },
		signal: init.signal || AbortSignal.timeout(FETCH_TIMEOUT_MS),
	});
	if (!response.ok) {
		throw new Error(`HTTP ${response.status}: ${url.split('?')[0]}`);
	}
	return response.text();
}

async function loadDetails(ids, fetchImpl = fetch) {
	const list = [...new Set(ids.map(String).filter(Boolean))];
	if (!list.length) return new Map();
	const body = new URLSearchParams({ itemcount: String(list.length) });
	list.forEach((id, index) => body.set(`publishedfileids[${index}]`, id));
	const text = await fetchText('https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/', { method: 'POST', body }, fetchImpl);
	const details = new Map();
	for (const raw of (JSON.parse(text).response || {}).publishedfiledetails || []) {
		const item = parseDetail(raw);
		if (item) details.set(item.id, item);
	}
	return details;
}

/** 浏览一页并补全详情（补全失败只记日志，保留浏览页数据）。 */
async function browse(options, fetchImpl = fetch) {
	const html = await fetchText(browseUrl(options), {}, fetchImpl);
	const page = parseBrowsePage(html, options.page || 1);
	try {
		const details = await loadDetails(page.items.map(item => item.id), fetchImpl);
		page.items = page.items.map(item => {
			const detail = details.get(item.id);
			return detail ? { ...item, ...detail, author: item.author || detail.author, description: detail.description || item.description, previewUrl: detail.previewUrl || item.previewUrl } : item;
		});
	} catch (error) {
		log().w('workshop', '补全创意工坊条目详情失败（仍显示浏览页数据）', error);
	}
	return page;
}

async function loadItem(id, fetchImpl = fetch) {
	const details = await loadDetails([id], fetchImpl);
	const item = details.get(String(id));
	if (!item) {
		throw new Error('workshop_not_found');
	}
	let community = { description: '', screenshots: [], required: [] };
	try {
		const url = `https://steamcommunity.com/sharedfiles/filedetails/?id=${encodeURIComponent(id)}&l=schinese`;
		community = parseCommunityDetail(await fetchText(url, {}, fetchImpl));
	} catch (error) {
		log().w('workshop', `读取创意工坊详情页失败: ${id}`, error);
	}
	if (community.required.length) {
		try {
			const deps = await loadDetails(community.required.map(r => r.id), fetchImpl);
			community.required = community.required.map(r => ({ ...r, ...(deps.get(r.id) ? { title: deps.get(r.id).title, previewUrl: deps.get(r.id).previewUrl, size: deps.get(r.id).size } : {}) }));
		} catch (error) {
			log().w('workshop', `读取前置 MOD 详情失败: ${id}`, error);
		}
	}
	return { ...item, description: community.description || item.description, screenshots: community.screenshots.length ? community.screenshots : (item.previewUrl ? [item.previewUrl] : []), required: community.required };
}

/** Steam 客户端下载的创意工坊内容目录：<库>/steamapps/workshop/content/2868840/<id>/。 */
function contentDirs(libraries) {
	const out = new Map();
	for (const library of libraries) {
		const root = path.join(library, 'steamapps', 'workshop', 'content', APP_ID);
		let names = [];
		try {
			names = fs.readdirSync(root, { withFileTypes: true }).filter(entry => entry.isDirectory() && /^\d+$/.test(entry.name)).map(entry => entry.name);
		} catch (error) {
			if (error.code !== 'ENOENT') log().w('workshop', `读取 Steam 创意工坊内容目录失败: ${root}`, error);
			continue;
		}
		for (const name of names) {
			const dir = path.join(root, name);
			const stat = fs.statSync(dir);
			if (!out.has(name) || out.get(name).mtimeMs < stat.mtimeMs) {
				out.set(name, { id: name, dir, mtimeMs: stat.mtimeMs });
			}
		}
	}
	return out;
}

class WorkshopLibrary {
	constructor(file) {
		this.file = file;
	}

	read() {
		try {
			const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
			return raw && typeof raw.items === 'object' ? raw : { items: {} };
		} catch (error) {
			if (error.code !== 'ENOENT') log().w('workshop', `创意工坊下载记录读取失败: ${this.file}`, error);
			return { items: {} };
		}
	}

	list() {
		return Object.values(this.read().items).sort((a, b) => (b.installedAt || 0) - (a.installedAt || 0));
	}

	get(id) {
		return this.read().items[String(id)] || null;
	}

	record(entry) {
		const data = this.read();
		data.items[String(entry.id)] = { ...data.items[String(entry.id)], ...entry, installedAt: Date.now() };
		this.write(data);
		return data.items[String(entry.id)];
	}

	remove(id) {
		const data = this.read();
		delete data.items[String(id)];
		this.write(data);
	}

	write(data) {
		fs.mkdirSync(path.dirname(this.file), { recursive: true });
		const temp = `${this.file}.${process.pid}.tmp`;
		fs.writeFileSync(temp, JSON.stringify(data, null, 2), 'utf8');
		fs.renameSync(temp, this.file);
	}
}

/** 远端更新时间晚于导入时记录的时间 → 有更新。 */
function hasUpdate(entry, remote) {
	return !!(entry && remote && remote.timeUpdated && entry.timeUpdated && remote.timeUpdated > entry.timeUpdated);
}

/** 下载旧式直链 file_url 到 dest（限制 1 GiB），返回文件路径。 */
async function downloadFile(url, dest, onProgress = () => {}, fetchImpl = fetch) {
	if (!/^https:\/\//i.test(url)) {
		throw new Error('workshop_bad_url');
	}
	const response = await fetchImpl(url, { headers: { 'User-Agent': USER_AGENT }, signal: AbortSignal.timeout(10 * 60 * 1000) });
	if (!response.ok) {
		throw new Error(`HTTP ${response.status}`);
	}
	const total = Number(response.headers.get('content-length')) || 0;
	fs.mkdirSync(path.dirname(dest), { recursive: true });
	const out = fs.openSync(`${dest}.part`, 'w');
	let received = 0;
	try {
		const reader = response.body.getReader();
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			received += value.length;
			if (received > MAX_DIRECT_DOWNLOAD_BYTES) {
				reader.cancel().catch(error => log().d('workshop', '取消超大下载失败', error));
				throw new Error('workshop_too_large');
			}
			fs.writeSync(out, value);
			onProgress(received, total);
		}
	} finally {
		fs.closeSync(out);
	}
	fs.renameSync(`${dest}.part`, dest);
	return dest;
}

module.exports = {
	APP_ID,
	SORTS,
	DAYS,
	parseWorkshopRef,
	browseUrl,
	parseBrowsePage,
	parseDetail,
	parseCommunityDetail,
	normalizeImageUrl,
	loadDetails,
	browse,
	loadItem,
	contentDirs,
	WorkshopLibrary,
	hasUpdate,
	downloadFile,
	stripTags,
};
