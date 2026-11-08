'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const webdav = require('../src/main/webdav');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-webdav-test-'));
}

function sha1(text) {
	return crypto.createHash('sha1').update(text).digest('hex');
}

/** 内存里的最小 WebDAV 服务器：PROPFIND / MKCOL / GET / PUT。 */
function fakeServer(basePath = '/dav/') {
	const files = new Map();
	const dirs = new Set(['']);
	const requests = [];
	const fetchImpl = async (url, init) => {
		const pathname = decodeURIComponent(new URL(url).pathname);
		const rel = pathname.slice(basePath.length).replace(/\/$/, '');
		requests.push({ method: init.method, rel, auth: init.headers.Authorization });
		if (init.method === 'MKCOL') {
			dirs.add(rel);
			return new Response('', { status: 201 });
		}
		if (init.method === 'PUT') {
			files.set(rel, Buffer.from(init.body));
			return new Response('', { status: 201 });
		}
		if (init.method === 'GET') {
			return files.has(rel) ? new Response(files.get(rel)) : new Response('', { status: 404 });
		}
		if (init.method === 'PROPFIND') {
			if (!dirs.has(rel) && !files.has(rel)) return new Response('', { status: 404 });
			const children = [`<d:response><d:href>${basePath}${rel ? `${rel}/` : ''}</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>`];
			if (init.headers.Depth === '1') {
				const prefix = rel ? `${rel}/` : '';
				for (const dir of dirs) {
					if (dir.startsWith(prefix) && dir !== rel && !dir.slice(prefix.length).includes('/')) {
						children.push(`<d:response><d:href>${basePath}${encodeURI(dir)}/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>`);
					}
				}
				for (const [file, data] of files) {
					if (file.startsWith(prefix) && !file.slice(prefix.length).includes('/')) {
						children.push(`<d:response><d:href>${basePath}${encodeURI(file)}</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>${data.length}</d:getcontentlength><d:getetag>"${sha1(data).slice(0, 8)}"</d:getetag></d:prop></d:propstat></d:response>`);
					}
				}
			}
			return new Response(`<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${children.join('')}</d:multistatus>`, { status: 207 });
		}
		return new Response('', { status: 405 });
	};
	return { files, dirs, requests, fetchImpl };
}

function writeSave(account, relative, text) {
	const file = path.join(account, relative);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
}

test('only whitelisted STS2 save files are synced', () => {
	const ok = ['profile.save', 'modded/profile.save', 'profile1/saves/progress.save', 'profile3/saves/current_run_mp.save.backup', 'modded/profile2/saves/history/123.run'];
	const bad = ['settings.save', 'profile4/saves/progress.save', 'profile1/saves/history/x/1.run', 'profile1/saves/other.save', '../profile.save', 'C:/x', 'logs/godot.log'];
	ok.forEach(p => assert.strictEqual(webdav.isSupportedPath(p, false), true, p));
	bad.forEach(p => assert.strictEqual(webdav.isSupportedPath(p, false), false, p));
	assert.strictEqual(webdav.isSupportedPath('settings.save', true), true);
	assert.strictEqual(webdav.sanitizeId(' My Slot!! '), 'my-slot');
});

test('parses PROPFIND multistatus with any namespace prefix', () => {
	const xml = '<D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/SlayTheSpire2/saves/a%20b/x.save</D:href><D:propstat><D:prop><D:getcontentlength>12</D:getcontentlength><D:getlastmodified>Sun, 09 Nov 2026 04:00:00 GMT</D:getlastmodified><D:getetag>&quot;e1&quot;</D:getetag><D:resourcetype/></D:prop></D:propstat></D:response></D:multistatus>';
	assert.deepStrictEqual(webdav.parseMultistatus(xml, '/dav/'), [{ path: 'SlayTheSpire2/saves/a b/x.save', collection: false, size: 12, lastModifiedMs: Date.UTC(2026, 10, 9, 4), etag: '"e1"' }]);
});

test('plans downloads and uploads against the common baseline like Android', () => {
	const entry = (p, hash) => ({ path: p, sha1: hash, size: 1 });
	const baseline = { entries: [{ local_relative_path: 'a', local_sha1: 'x', remote_sha1: 'x' }, { local_relative_path: 'b', local_sha1: 'x', remote_sha1: 'y' }] };
	// a：只有远端改了 → 下载；c：本地没有 → 下载。
	assert.deepStrictEqual(webdav.planDownloads([entry('a', 'r'), entry('c', 'r')], [entry('a', 'x')], baseline, false).map(e => e.path), ['a', 'c']);
	// a：本地改了、远端没改 → 保留本地，不下载。
	assert.deepStrictEqual(webdav.planDownloads([entry('a', 'x')], [entry('a', 'l')], baseline, false), []);
	// a：双方都改了 → 冲突；b 的 baseline 双方不一致，不算共同祖先 → 也冲突。
	assert.throws(() => webdav.planDownloads([entry('a', 'r'), entry('b', 'r')], [entry('a', 'l'), entry('b', 'l')], baseline, false), err => err.conflicts.join() === 'a,b');
	assert.strictEqual(webdav.planDownloads([entry('a', 'r')], [entry('a', 'l')], baseline, true).length, 1);
	// 上传：本地改了、远端没改 → 上传；远端改了本地没改 → 不上传；都改了 → 冲突。
	assert.deepStrictEqual(webdav.planUploads([entry('a', 'l')], [entry('a', 'x')], baseline, false).map(e => e.path), ['a']);
	assert.deepStrictEqual(webdav.planUploads([entry('a', 'x')], [entry('a', 'r')], baseline, false), []);
	assert.throws(() => webdav.planUploads([entry('a', 'l')], [entry('a', 'r')], baseline, false), err => err instanceof webdav.CloudConflictError);
	assert.deepStrictEqual(webdav.planUploads([entry('a', 'l')], [entry('a', 'r')], baseline, true).map(e => e.path), ['a']);
});

test('pushes, pulls with backup and detects conflicts end to end', async () => {
	const server = fakeServer();
	const accountA = tempDir();
	const accountB = tempDir();
	const config = { url: 'https://dav.example/dav', username: 'u', password: 'p', slot: '' };
	const syncA = new webdav.WebDavSync({ config, accountDir: accountA, stateDir: tempDir(), profileId: 'Profile-1' }, server.fetchImpl);
	const syncB = new webdav.WebDavSync({ config, accountDir: accountB, stateDir: tempDir(), profileId: 'Profile-1' }, server.fetchImpl);
	assert.strictEqual(syncA.remoteDir, 'SlayTheSpire2/saves/profile-1');
	writeSave(accountA, 'profile1/saves/progress.save', 'progress v1');
	writeSave(accountA, 'profile1/saves/history/1.run', 'run');
	writeSave(accountA, 'settings.save', 'secret settings');
	assert.deepStrictEqual(await syncA.push(), { uploaded: 2 });
	assert.ok(server.files.has('SlayTheSpire2/saves/profile-1/profile1/saves/progress.save'));
	assert.ok(!server.files.has('SlayTheSpire2/saves/profile-1/settings.save'), 'settings.save is not synced by default');
	assert.ok(server.files.has('SlayTheSpire2/saves/profile-1/.sts2re/manifest.json'));
	assert.ok(server.requests.every(r => r.auth === `Basic ${Buffer.from('u:p').toString('base64')}`));

	const pulled = await syncB.pull();
	assert.strictEqual(pulled.downloaded, 2);
	assert.match(pulled.backup, /^sts2-webdav-pull-backup-.*\.zip$/);
	assert.strictEqual(fs.readFileSync(path.join(accountB, 'profile1/saves/progress.save'), 'utf8'), 'progress v1');
	assert.deepStrictEqual(await syncB.pull(), { downloaded: 0, preserved: 2, backup: '' });

	// 两边都改同一个文件 → B 上传时冲突；选择保留本地后强制上传。
	writeSave(accountA, 'profile1/saves/progress.save', 'progress A');
	await syncA.push();
	writeSave(accountB, 'profile1/saves/progress.save', 'progress B');
	await assert.rejects(syncB.push(), err => err instanceof webdav.CloudConflictError && err.conflicts[0] === 'profile1/saves/progress.save');
	await assert.rejects(syncB.pull(), err => err instanceof webdav.CloudConflictError);
	assert.deepStrictEqual(await syncB.push(true), { uploaded: 1 });
	// A 现在只有远端变化 → 正常拉取覆盖。
	assert.strictEqual((await syncA.pull()).downloaded, 1);
	assert.strictEqual(fs.readFileSync(path.join(accountA, 'profile1/saves/progress.save'), 'utf8'), 'progress B');
});

test('rejects bad WebDAV urls', () => {
	for (const url of ['ftp://x', 'https://u:p@x/dav', 'https://x/dav?q=1', 'nope']) {
		assert.throws(() => new webdav.WebDavClient({ url }), /webdav_bad_url/);
	}
	assert.strictEqual(new webdav.WebDavClient({ url: 'https://x/dav' }).url('a b/c', false), 'https://x/dav/a%20b/c');
});
