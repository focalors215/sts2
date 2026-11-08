'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const nexus = require('../src/main/nexus');

test('parses mod ids and nxm links', () => {
	assert.strictEqual(nexus.parseModId('42'), '42');
	assert.strictEqual(nexus.parseModId('https://www.nexusmods.com/slaythespire2/mods/42?tab=files'), '42');
	assert.strictEqual(nexus.parseModId('cool mod'), '');
	assert.deepStrictEqual(nexus.parseNxmLink('nxm://slaythespire2/mods/42/files/7?key=abc&expires=123&user_id=9'),
		{ gameDomain: 'slaythespire2', modId: '42', fileId: '7', key: 'abc', expires: '123' });
	assert.strictEqual(nexus.parseNxmLink('nxm://slaythespire2/mods/42/files/7'), null);
});

test('sorts files with primary / main first and keeps only https links', () => {
	const files = nexus.parseFiles({ files: [
		{ file_id: 1, name: 'Optional', category_name: 'OPTIONAL' },
		{ file_id: 2, name: 'Main', category_name: 'MAIN', size_kb: 2 },
		{ file_id: 3, name: 'Update', category_name: 'UPDATE', is_primary: false },
	] });
	assert.deepStrictEqual(files.map(f => [f.fileId, f.primary]), [['2', true], ['3', false], ['1', false]]);
	assert.strictEqual(files[0].size, 2048);
	assert.deepStrictEqual(nexus.parseDownloadLinks([{ name: 'CDN', URI: 'https://cdn/x.zip' }, { URI: 'http://bad' }]), [{ name: 'CDN', uri: 'https://cdn/x.zip' }]);
});

test('client sends the api key, maps errors and downloads with a file name', async () => {
	const calls = [];
	const fakeFetch = async (url, init) => {
		calls.push({ url, headers: init.headers });
		if (url.endsWith('/users/validate.json')) return new Response(JSON.stringify({ name: 'Ann', is_premium: false }));
		if (url.includes('/download_link.json')) return url.includes('key=') ? new Response(JSON.stringify([{ name: 'CDN', URI: 'https://cdn.test/files/Mod%20One.zip?x=1' }])) : new Response('{"message":"premium"}', { status: 403 });
		if (url.startsWith('https://cdn.test/')) return new Response('zip-bytes', { headers: { 'content-disposition': 'attachment; filename="Mod One.zip"' } });
		return new Response('{}', { status: 404 });
	};
	const client = new nexus.NexusClient('k-123456', { version: '1.0', fetchImpl: fakeFetch });
	assert.deepStrictEqual(await client.validate(), { name: 'Ann', premium: false });
	assert.strictEqual(calls[0].headers.apikey, 'k-123456');
	assert.strictEqual(calls[0].headers['Application-Name'], 'STS2CottageLauncher');
	await assert.rejects(client.downloadLinks('42', '7'), /nexus_premium_required/);
	const links = await client.downloadLinks('42', '7', { key: 'a b', expires: '9' });
	assert.match(calls.at(-1).url, /download_link\.json\?key=a%20b&expires=9$/);
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-nexus-test-'));
	const file = await client.download(links[0].uri, dir, 'fallback.zip');
	assert.strictEqual(path.basename(file), 'Mod One.zip');
	assert.strictEqual(fs.readFileSync(file, 'utf8'), 'zip-bytes');
	await assert.rejects(new nexus.NexusClient('', { fetchImpl: fakeFetch }).getMod('1'), /nexus_no_key/);
	await assert.rejects(client.getMod('999'), /nexus_not_found/);
});
