'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const yazl = require('yazl');
const { parseVdf, getKey } = require('../src/main/vdf');
const game = require('../src/main/game');
const mods = require('../src/main/mods');
const saves = require('../src/main/saves');
const { safeEntryName } = require('../src/main/ziputil');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-launcher-test-'));
}

function writeJson(file, json) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, JSON.stringify(json));
}

function makeZip(file, entries) {
	return new Promise(resolve => {
		const zip = new yazl.ZipFile();
		for (const [name, content] of Object.entries(entries)) {
			zip.addBuffer(Buffer.from(content), name);
		}
		zip.outputStream.pipe(fs.createWriteStream(file)).on('close', resolve);
		zip.end();
	});
}

test('parses Steam library folders and app manifests', () => {
	const vdf = parseVdf('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"D:\\\\SteamLibrary"\n\t}\n}\n');
	assert.strictEqual(getKey(getKey(vdf, 'LibraryFolders')['0'], 'path'), 'D:\\SteamLibrary');
	const acf = parseVdf('"AppState" { "installdir" "Slay the Spire 2" "UserConfig" { "BetaKey" "public-beta" } }');
	assert.strictEqual(getKey(getKey(getKey(acf, 'AppState'), 'userconfig'), 'betakey'), 'public-beta');
});

test('builds launch arguments like the Android log level bridge', () => {
	const args = game.buildLaunchArgs({ windowMode: 'windowed', renderer: 'vulkan', logLevel: 'very_debug', extraArgs: '--foo "a b"' }, { extraArgs: '--bar' });
	assert.deepStrictEqual(args.slice(0, 3), ['--windowed', '--rendering-driver', 'vulkan']);
	assert.strictEqual(args.filter(a => a === '-log').length, 5);
	assert.ok(args.includes('VeryDebug'));
	assert.deepStrictEqual(args.slice(-3), ['--foo', 'a b', '--bar']);
	assert.deepStrictEqual(game.buildLaunchArgs({ windowMode: 'default', renderer: 'default', logLevel: 'off', extraArgs: '' }, null), []);
});

test('inspects a game directory', async () => {
	const dir = tempDir();
	assert.strictEqual((await game.inspectGameDir(dir)).ready, false);
	for (const file of game.REQUIRED_FILES) {
		fs.mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
		fs.writeFileSync(path.join(dir, file), file === 'release_info.json' ? '{"version":"v0.111.0"}' : 'x');
	}
	const info = await game.inspectGameDir(dir);
	assert.strictEqual(info.ready, true);
	assert.strictEqual(info.version, 'v0.111.0');
	assert.match(info.dllSha256, /^[0-9a-f]{64}$/);
});

test('mod states, warnings and load order fix follow settings.save mod_list', () => {
	const root = tempDir();
	writeJson(path.join(root, 'Base', 'BaseLib.json'), { id: 'BaseLib', has_dll: true });
	fs.writeFileSync(path.join(root, 'Base', 'BaseLib.dll'), 'x');
	writeJson(path.join(root, 'Card', 'mod_manifest.json'), { id: 'Card', dependencies: ['BaseLib', { id: 'Missing' }], has_pck: true });
	writeJson(path.join(root, 'Bad', 'bad.json'), { id: '../escape' });
	const settings = { mod_settings: { mods_enabled: true, mod_list: [{ id: 'Card', source: 'mods_directory', is_enabled: true }, { id: 'BaseLib', source: 'mods_directory', is_enabled: false }] } };
	const view = mods.describeMods(root, settings, 'v0.111.0');
	assert.deepStrictEqual(view.mods.map(m => m.id), ['Card', 'BaseLib']);
	const card = view.mods[0];
	assert.deepStrictEqual(card.warnings.map(w => w.kind).sort(), ['disabled_dependency', 'missing_dependency', 'missing_pck']);
	mods.setDisabled(settings, 'BaseLib', false);
	assert.ok(mods.describeMods(root, settings).mods.find(m => m.id === 'Card').warnings.some(w => w.kind === 'order'));
	mods.fixLoadOrder(settings, mods.describeMods(root, settings).mods);
	assert.deepStrictEqual(settings.mod_settings.mod_list.map(i => i.id), ['BaseLib', 'Card']);
	assert.strictEqual(settings.mod_settings.mod_list[0].is_enabled, true);
});

test('import detects same-id conflicts, replaces on commit and adds manifest aliases', async () => {
	const dir = tempDir();
	const modsDir = path.join(dir, 'mods');
	writeJson(path.join(modsDir, 'OldFolder', 'Cool.json'), { id: 'Cool', version: '1' });
	const zip = path.join(dir, 'cool.zip');
	await makeZip(zip, { 'CoolMod/mod_manifest.json': JSON.stringify({ id: 'Cool', version: '2' }), 'CoolMod/Cool.dll': 'dll' });
	const plan = await mods.prepareImport(path.join(dir, 'staging'), modsDir, zip);
	assert.strictEqual(plan.folder, 'CoolMod');
	assert.deepStrictEqual(plan.conflicts.map(c => c.id), ['Cool']);
	mods.commitImport(plan.token);
	assert.ok(!fs.existsSync(path.join(modsDir, 'OldFolder')));
	assert.ok(fs.existsSync(path.join(modsDir, 'CoolMod', 'Cool.json')));
	const installed = mods.scanManifests(modsDir);
	assert.strictEqual(installed.length, 1);
	assert.strictEqual(installed[0].version, '2');
	mods.deleteMod(modsDir, installed[0]);
	assert.ok(!fs.existsSync(path.join(modsDir, 'CoolMod')));
});

test('import rejects zip slip entries and zips without manifests', async () => {
	assert.strictEqual(safeEntryName('../evil.dll'), null);
	assert.strictEqual(safeEntryName('C:/evil.dll'), null);
	assert.strictEqual(safeEntryName('a\\b.json'), 'a/b.json');
	const dir = tempDir();
	const zip = path.join(dir, 'empty.zip');
	await makeZip(zip, { 'readme.txt': 'hi' });
	await assert.rejects(mods.prepareImport(path.join(dir, 'staging'), path.join(dir, 'mods'), zip), /no_manifest/);
	assert.deepStrictEqual(fs.readdirSync(path.join(dir, 'staging')), []);
});

test('snapshots round-trip, prune automatic ones and keep a before-restore backup', async () => {
	const dir = tempDir();
	const saveRoot = path.join(dir, 'SlayTheSpire2');
	writeJson(path.join(saveRoot, 'steam', '765', 'settings.save'), { v: 1 });
	writeJson(path.join(saveRoot, 'steam', '765', 'profile1', 'saves', 'progress.save'), { gold: 1 });
	const [account] = saves.listAccounts(saveRoot);
	assert.strictEqual(account.id, 'steam/765');
	const data = path.join(dir, 'data');
	const manual = await saves.createSnapshot(data, account, 'manual', 2);
	for (let i = 0; i < 3; i++) {
		await saves.createSnapshot(data, account, 'before-launch', 2);
	}
	const list = saves.listSnapshots(data, account);
	assert.strictEqual(list.filter(s => s.reason === 'before-launch').length, 2);
	assert.ok(list.some(s => s.path === manual));
	writeJson(path.join(account.path, 'profile1', 'saves', 'progress.save'), { gold: 999 });
	fs.writeFileSync(path.join(account.path, 'extra.save'), 'new');
	await saves.restoreSnapshot(data, account, manual, 2);
	assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(account.path, 'profile1', 'saves', 'progress.save'))), { gold: 1 });
	assert.ok(!fs.existsSync(path.join(account.path, 'extra.save')));
	assert.ok(saves.listSnapshots(data, account).some(s => s.reason === 'before-restore'));
	assert.deepStrictEqual(fs.readdirSync(path.join(saveRoot, 'steam')), ['765']);
});
