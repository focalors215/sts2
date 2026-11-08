'use strict';

/*
 * 启动器更新检查（对齐 Android ExtraSettingsUpdateChecker）：读取 GitHub releases，跳过草稿；
 * 同一仓库也发布 Android APK，所以只看带 Windows 启动器产物（sts2-cottage-launcher-*-win-*）的 release，
 * 版本号取产物文件名 / tag 中的版本。只提示并打开 release 页面，不自动下载安装。
 */
const { log } = require('./logger');

const RELEASES_API_URL = 'https://api.github.com/repos/ModinMobileSTS/Sts2MobileLauncher/releases?per_page=30';
const RELEASES_URL = 'https://github.com/ModinMobileSTS/Sts2MobileLauncher/releases';
const ASSET_PATTERN = /sts2-cottage-launcher-v?(\d+(?:\.\d+)+(?:-[0-9A-Za-z.-]+)?)-win-[^/]*\.(?:zip|exe)$/i;
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

/** "v0.1.2" / "windows-v0.1.2-beta" → { parts: [0,1,2], preRelease }；解析不了返回 null。 */
function parseVersion(label) {
	const match = /(?:^|[^0-9A-Za-z])v?(\d+(?:\.\d+)*)([-+][0-9A-Za-z.-]+)?(?:$|[^0-9A-Za-z])/i.exec(String(label || ''));
	if (!match) return null;
	return { parts: match[1].split('.').map(Number), preRelease: !!match[2] && match[2].startsWith('-') };
}

function compareVersions(a, b) {
	const left = parseVersion(a);
	const right = parseVersion(b);
	if (!left || !right) {
		return String(a).replace(/^v/i, '') === String(b).replace(/^v/i, '') ? 0 : -1;
	}
	for (let i = 0; i < Math.max(left.parts.length, right.parts.length); i++) {
		const diff = (left.parts[i] || 0) - (right.parts[i] || 0);
		if (diff !== 0) return diff > 0 ? 1 : -1;
	}
	if (left.preRelease !== right.preRelease) return left.preRelease ? -1 : 1;
	return 0;
}

/** 从 release 列表里挑最新的 Windows 启动器 release。 */
function pickWindowsRelease(releases) {
	let best = null;
	for (const release of Array.isArray(releases) ? releases : []) {
		if (!release || release.draft) continue;
		const asset = (release.assets || []).find(item => ASSET_PATTERN.test(item.name || ''));
		if (!asset) continue;
		const version = ASSET_PATTERN.exec(asset.name)[1];
		if (!best || compareVersions(version, best.version) > 0) {
			best = { version, name: release.name || release.tag_name || version, notes: release.body || '', url: release.html_url || RELEASES_URL, prerelease: release.prerelease === true, asset: asset.name };
		}
	}
	return best;
}

async function checkForUpdate(currentVersion, fetchImpl = fetch) {
	let response;
	try {
		response = await fetchImpl(RELEASES_API_URL, {
			headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': `STS2CottageLauncher/${currentVersion} Windows` },
			signal: AbortSignal.timeout(30000),
		});
	} catch (error) {
		const wrapped = new Error('update_network');
		wrapped.cause = error;
		throw wrapped;
	}
	if (response.status === 404) {
		log().d('update', 'GitHub releases 不公开或不存在，跳过更新检查');
		return { status: 'unavailable', releasesUrl: RELEASES_URL };
	}
	if (!response.ok) {
		throw new Error(`update_http_${response.status}`);
	}
	const latest = pickWindowsRelease(await response.json());
	if (!latest) {
		return { status: 'unavailable', releasesUrl: RELEASES_URL };
	}
	const comparison = compareVersions(latest.version, currentVersion);
	log().i('update', `当前 ${currentVersion}，最新 Windows 启动器 ${latest.version}（${comparison > 0 ? '有更新' : '已是最新'}）`);
	return { status: comparison > 0 ? 'update' : 'latest', current: currentVersion, ...latest, releasesUrl: RELEASES_URL };
}

function shouldAutoCheck(section, now = Date.now()) {
	return section.autoCheck !== false && (!section.lastCheckAt || now - section.lastCheckAt >= CHECK_INTERVAL_MS);
}

module.exports = { RELEASES_URL, parseVersion, compareVersions, pickWindowsRelease, checkForUpdate, shouldAutoCheck };
