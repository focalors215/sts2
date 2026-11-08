'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const updater = require('../src/main/update');
const backup = require('../src/main/backup');
const files = require('../src/main/files');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-tools-test-'));
}

function write(file, text) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
}

test('compares versions and picks the newest Windows launcher release', async () => {
	assert.strictEqual(updater.compareVersions('v0.1.10', '0.1.9'), 1);
	assert.strictEqual(updater.compareVersions('0.2.0-beta', '0.2.0'), -1);
	assert.strictEqual(updater.compareVersions('v0.1.2', '0.1.2'), 0);
	const releases = [
		{ draft: true, assets: [{ name: 'sts2-cottage-launcher-9.9.9-win-x64.zip' }] },
		{ tag_name: 'v0.1.20', assets: [{ name: 'sts2-re-importer.apk' }] },
		{ tag_name: 'win-0.1.3', html_url: 'https://gh/r/3', body: 'notes', assets: [{ name: 'sts2-cottage-launcher-0.1.3-win-x64.exe' }] },
		{ tag_name: 'win-0.1.4-beta', prerelease: true, assets: [{ name: 'sts2-cottage-launcher-0.1.4-beta-win-x64.zip' }] },
	];
	const picked = updater.pickWindowsRelease(releases);
	assert.strictEqual(picked.version, '0.1.4-beta');
	assert.strictEqual(picked.prerelease, true);
	const fakeFetch = async () => new Response(JSON.stringify(releases.slice(0, 3)));
	const result = await updater.checkForUpdate('0.1.2', fakeFetch);
	assert.deepStrictEqual([result.status, result.version, result.url], ['update', '0.1.3', 'https://gh/r/3']);
	assert.strictEqual((await updater.checkForUpdate('0.1.3', fakeFetch)).status, 'latest');
	assert.strictEqual((await updater.checkForUpdate('0.1.3', async () => new Response('[]'))).status, 'unavailable');
	assert.strictEqual((await updater.checkForUpdate('0.1.3', async () => new Response('', { status: 404 }))).status, 'unavailable');
	await assert.rejects(updater.checkForUpdate('0.1.3', async () => { throw new Error('offline'); }), /update_network/);
	assert.strictEqual(updater.shouldAutoCheck({}), true);
	assert.strictEqual(updater.shouldAutoCheck({ autoCheck: false }), false);
	assert.strictEqual(updater.shouldAutoCheck({ lastCheckAt: Date.now() - 1000 }), false);
});

test('exports and restores a full data backup with rollback-safe replacement', async () => {
	const saveRoot = path.join(tempDir(), 'SlayTheSpire2');
	const modsDir = path.join(tempDir(), 'mods');
	write(path.join(saveRoot, 'default', '1', 'settings.save'), '{"a":1}');
	write(path.join(saveRoot, 'default', '1', 'profile1', 'saves', 'progress.save'), 'p1');
	write(path.join(saveRoot, 'logs', 'godot.log'), 'log');
	write(path.join(saveRoot, 'launcher', 'pending-action.json'), '{}');
	write(path.join(modsDir, 'ModA', 'ModA.json'), '{"id":"ModA"}');
	assert.deepStrictEqual(backup.saveFiles(saveRoot).sort(), ['default/1/profile1/saves/progress.save', 'default/1/settings.save']);
	const measure = backup.measure({ saveRoot, modsDir });
	assert.deepStrictEqual([measure.saveFiles, measure.modFiles], [2, 1]);
	const zip = path.join(tempDir(), backup.backupName(new Date(2026, 10, 9)));
	assert.ok(zip.endsWith('sts2-full-backup-windows-20261109-000000.zip'));
	const manifest = await backup.createBackup(zip, { saveRoot, launcherConfig: { online: { playerId: '42' } }, modsDir, includeMods: true, launcherVersion: '0.2.0' });
	assert.deepStrictEqual(manifest.includes, { saves: 2, launcherConfig: true, mods: 1 });

	// 修改当前数据后恢复。
	write(path.join(saveRoot, 'default', '1', 'profile1', 'saves', 'progress.save'), 'changed');
	write(path.join(saveRoot, 'default', '1', 'extra.save'), 'new');
	fs.rmSync(path.join(modsDir, 'ModA'), { recursive: true });
	write(path.join(modsDir, 'ModB', 'ModB.json'), '{}');
	const opened = await backup.openBackup(zip, path.join(tempDir(), 'work'));
	const result = backup.restoreBackup(opened, { saveRoot, modsDir });
	assert.strictEqual(fs.readFileSync(path.join(saveRoot, 'default', '1', 'profile1', 'saves', 'progress.save'), 'utf8'), 'p1');
	assert.strictEqual(fs.existsSync(path.join(saveRoot, 'default', '1', 'extra.save')), false);
	assert.strictEqual(fs.readFileSync(path.join(saveRoot, 'logs', 'godot.log'), 'utf8'), 'log', 'logs are kept');
	assert.ok(fs.existsSync(path.join(modsDir, 'ModA', 'ModA.json')) && fs.existsSync(path.join(modsDir, 'ModB', 'ModB.json')), 'mods are merged, not deleted');
	assert.strictEqual(result.launcherConfig.online.playerId, '42');
	assert.ok(!fs.readdirSync(path.dirname(saveRoot)).some(name => name.includes('rollback')));

	const bogus = path.join(tempDir(), 'bogus.zip');
	fs.writeFileSync(bogus, 'not a zip');
	await assert.rejects(backup.openBackup(bogus, path.join(tempDir(), 'w2')), /backup_invalid/);
});

test('file browser stays inside its roots and edits text safely', () => {
	const root = tempDir();
	const roots = [{ id: 'saves', path: root }];
	write(path.join(root, 'default', '1', 'settings.save'), '{"x":1}');
	write(path.join(root, 'secrets.json'), '{}');
	write(path.join(root, 'bin.dat'), Buffer.from([1, 0, 2]));
	const listing = files.list(roots, 'saves', '');
	assert.deepStrictEqual(listing.entries.map(e => [e.name, e.dir]), [['default', true], ['bin.dat', false], ['secrets.json', false]]);
	assert.throws(() => files.list(roots, 'saves', '../..'), /files_bad_path/);
	assert.throws(() => files.list(roots, 'other', ''), /files_bad_root/);
	assert.throws(() => files.readText(roots, 'saves', 'secrets.json'), /files_protected/);
	assert.throws(() => files.readText(roots, 'saves', 'bin.dat'), /files_binary/);
	const read = files.readText(roots, 'saves', 'default/1/settings.save');
	assert.strictEqual(read.text, '{"x":1}');
	assert.throws(() => files.writeText(roots, 'saves', 'default/1/settings.save', '{bad', read.mtimeMs), /files_bad_json/);
	assert.throws(() => files.writeText(roots, 'saves', 'default/1/settings.save', '{}', read.mtimeMs - 5000), /files_changed/);
	files.writeText(roots, 'saves', 'default/1/settings.save', '{"x":2}', read.mtimeMs);
	assert.strictEqual(fs.readFileSync(path.join(root, 'default', '1', 'settings.save'), 'utf8'), '{"x":2}');
	assert.strictEqual(fs.readFileSync(path.join(root, 'default', '1', 'settings.save.launcher-backup'), 'utf8'), '{"x":1}');
	if (process.platform !== 'win32') {
		fs.symlinkSync('/etc', path.join(root, 'link'));
		assert.throws(() => files.list(roots, 'saves', 'link'), /files_bad_path/);
	}
});
