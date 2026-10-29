'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { extractZip, listFiles } = require('./ziputil');

const MOD_SOURCE = 'mods_directory';
const pendingImports = new Map();

function firstNonEmpty(...values) {
	for (const value of values) {
		if (typeof value === 'string' && value.trim()) {
			return value.trim();
		}
	}
	return '';
}

/** 与 Android isSafeModBaseName 同一规则：manifest 里的 id / pck_name 只能是文件基名。 */
function isSafeModBaseName(name) {
	return typeof name === 'string' && name !== '' && name !== '.' && name !== '..'
		&& !/[\\/:*?"<>|\u0000-\u001f]/.test(name);
}

function readAuthors(manifest) {
	const direct = firstNonEmpty(manifest.author, manifest.authors, manifest.Author);
	if (direct) {
		return direct;
	}
	const list = Array.isArray(manifest.author_list) ? manifest.author_list : Array.isArray(manifest.contributors) ? manifest.contributors : [];
	return list.map(item => (item && typeof item === 'object' ? firstNonEmpty(item.name, item.id) : String(item).trim())).filter(Boolean).join(', ');
}

/** 只读必需依赖 dependencies（同原版 ModManifest），字符串或 {id, min_version} 均可。 */
function readDependencies(manifest) {
	const out = [];
	const seen = new Set();
	for (const item of Array.isArray(manifest.dependencies) ? manifest.dependencies : []) {
		const id = item && typeof item === 'object' ? firstNonEmpty(item.id, item.name, item.mod_id) : String(item || '').trim();
		if (id && !seen.has(id)) {
			seen.add(id);
			out.push({ id, minVersion: item && typeof item === 'object' ? firstNonEmpty(item.min_version, item.version) : '' });
		}
	}
	return out;
}

function hasSibling(dir, base, ext) {
	return isSafeModBaseName(base) && fs.existsSync(path.join(dir, base + ext));
}

function parseManifest(root, file) {
	let manifest;
	try {
		manifest = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
	} catch (error) {
		return null;
	}
	if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
		return null;
	}
	const id = firstNonEmpty(manifest.id, manifest.mod_id, manifest.modId, manifest.ID);
	if (!isSafeModBaseName(id)) {
		return null;
	}
	const dir = path.dirname(file);
	const pckName = firstNonEmpty(manifest.pck_name, manifest.pckName, manifest.PckName, id);
	return {
		id,
		pckName: isSafeModBaseName(pckName) ? pckName : id,
		name: firstNonEmpty(manifest.name, manifest.display_name, id),
		version: firstNonEmpty(manifest.version, manifest.mod_version, manifest.Version),
		author: readAuthors(manifest),
		description: firstNonEmpty(manifest.description, manifest.desc, manifest.Description),
		minGameVersion: firstNonEmpty(manifest.min_game_version, manifest.minGameVersion, manifest.game_version),
		dependencies: readDependencies(manifest),
		declaredHasPck: manifest.has_pck === true || manifest.hasPck === true,
		declaredHasDll: manifest.has_dll === true || manifest.hasDll === true,
		hasPck: hasSibling(dir, id, '.pck') || hasSibling(dir, pckName, '.pck'),
		hasDll: hasSibling(dir, id, '.dll') || hasSibling(dir, pckName, '.dll'),
		manifestPath: file,
		relativePath: path.relative(root, file).split(path.sep).join('/'),
		directory: dir,
		manifestName: path.basename(file),
	};
}

/** 递归扫描 MOD 根目录里的 manifest（不跟随符号链接）。 */
function scanManifests(root) {
	const results = [];
	const walk = (dir, depth) => {
		let entries;
		try {
			entries = fs.readdirSync(dir, { withFileTypes: true });
		} catch (error) {
			return;
		}
		for (const entry of entries) {
			const full = path.join(dir, entry.name);
			if (entry.isSymbolicLink()) {
				continue;
			}
			if (entry.isDirectory() && depth < 6) {
				walk(full, depth + 1);
			} else if (entry.isFile() && entry.name.toLowerCase().endsWith('.json')) {
				const mod = parseManifest(root, full);
				if (mod) {
					results.push(mod);
				}
			}
		}
	};
	walk(root, 0);
	// 同目录里 mod_manifest.json 与 <id>.json 并存时只保留后者。
	const byKey = new Map();
	for (const mod of results) {
		const key = `${mod.directory}|${mod.id}`;
		const existing = byKey.get(key);
		if (!existing || existing.manifestName.toLowerCase() === 'mod_manifest.json') {
			byKey.set(key, mod);
		}
	}
	return [...byKey.values()];
}

function modSettingsOf(settings) {
	if (!settings) {
		return null;
	}
	if (!settings.mod_settings || typeof settings.mod_settings !== 'object') {
		settings.mod_settings = { mods_enabled: false, mod_list: [] };
	}
	if (!Array.isArray(settings.mod_settings.mod_list)) {
		settings.mod_settings.mod_list = [];
	}
	return settings.mod_settings;
}

function isLocalSource(source) {
	const normalized = String(source || '').trim().toLowerCase().replace(/-/g, '_');
	return normalized === '' || normalized === MOD_SOURCE || normalized === 'modsdirectory' || normalized === 'local';
}

function findListEntry(modSettings, id) {
	return modSettings.mod_list.find(item => item && item.id === id && isLocalSource(item.source)) || null;
}

function isDisabled(settings, mod) {
	if (!settings || !settings.mod_settings) {
		return false;
	}
	const modSettings = modSettingsOf(settings);
	const entry = findListEntry(modSettings, mod.id) || (mod.pckName !== mod.id ? findListEntry(modSettings, mod.pckName) : null);
	if (entry) {
		return entry.is_enabled === false;
	}
	const legacy = Array.isArray(modSettings.disabled_mods) ? modSettings.disabled_mods : [];
	return legacy.some(item => item && (item.name === mod.id || item.name === mod.pckName) && isLocalSource(item.source));
}

function setDisabled(settings, id, disabled) {
	const modSettings = modSettingsOf(settings);
	let entry = findListEntry(modSettings, id);
	if (!entry) {
		entry = { id, source: MOD_SOURCE, is_enabled: true };
		modSettings.mod_list.push(entry);
	}
	entry.source = MOD_SOURCE;
	entry.is_enabled = !disabled;
	if (Array.isArray(modSettings.disabled_mods)) {
		modSettings.disabled_mods = modSettings.disabled_mods.filter(item => !(item && item.name === id && isLocalSource(item.source)));
	}
}

function removeFromList(settings, id) {
	if (!settings || !settings.mod_settings) {
		return;
	}
	const modSettings = modSettingsOf(settings);
	modSettings.mod_list = modSettings.mod_list.filter(item => !(item && item.id === id && isLocalSource(item.source)));
}

/** 启动器视图：MOD 列表 + 启用状态 + 依赖/文件/顺序问题（规则同 Android ModsPage）。 */
function describeMods(modsDir, settings, gameVersion) {
	const mods = fs.existsSync(modsDir) ? scanManifests(modsDir) : [];
	const ids = new Map();
	for (const mod of mods) {
		ids.set(mod.id, (ids.get(mod.id) || 0) + 1);
	}
	const order = settings && settings.mod_settings && Array.isArray(settings.mod_settings.mod_list)
		? settings.mod_settings.mod_list.filter(item => item && isLocalSource(item.source)).map(item => item.id)
		: [];
	const enabledIds = new Set(mods.filter(mod => !isDisabled(settings, mod)).map(mod => mod.id));
	const views = mods.map(mod => {
		const warnings = [];
		for (const dependency of mod.dependencies) {
			if (!ids.has(dependency.id)) {
				warnings.push({ kind: 'missing_dependency', target: dependency.id });
			} else if (!enabledIds.has(dependency.id) && enabledIds.has(mod.id)) {
				warnings.push({ kind: 'disabled_dependency', target: dependency.id });
			} else {
				const self = order.indexOf(mod.id);
				const dep = order.indexOf(dependency.id);
				if (self >= 0 && dep > self) {
					warnings.push({ kind: 'order', target: dependency.id });
				}
			}
		}
		if (mod.declaredHasPck && !mod.hasPck) {
			warnings.push({ kind: 'missing_pck', target: `${mod.pckName}.pck` });
		}
		if (mod.declaredHasDll && !mod.hasDll) {
			warnings.push({ kind: 'missing_dll', target: `${mod.id}.dll` });
		}
		if (!mod.declaredHasPck && !mod.declaredHasDll && !mod.hasPck && !mod.hasDll) {
			warnings.push({ kind: 'no_payload', target: mod.id });
		}
		if (ids.get(mod.id) > 1) {
			warnings.push({ kind: 'duplicate_id', target: mod.id });
		}
		if (mod.minGameVersion && gameVersion && compareVersions(gameVersion, mod.minGameVersion) < 0) {
			warnings.push({ kind: 'game_version', target: mod.minGameVersion });
		}
		const { directory, ...rest } = mod;
		return { ...rest, directory, enabled: enabledIds.has(mod.id), warnings };
	});
	const rank = id => {
		const index = order.indexOf(id);
		return index < 0 ? Number.MAX_SAFE_INTEGER : index;
	};
	views.sort((a, b) => rank(a.id) - rank(b.id) || a.name.localeCompare(b.name));
	return {
		modsDir,
		exists: fs.existsSync(modsDir),
		modsEnabled: !!(settings && settings.mod_settings && settings.mod_settings.mods_enabled),
		settingsAvailable: !!settings,
		mods: views,
		orderFixable: views.some(mod => mod.warnings.some(w => w.kind === 'order')),
	};
}

function compareVersions(a, b) {
	const parse = value => String(value).replace(/^v/i, '').split(/[.\-+]/).map(part => Number.parseInt(part, 10) || 0);
	const left = parse(a);
	const right = parse(b);
	for (let i = 0; i < Math.max(left.length, right.length); i++) {
		const diff = (left[i] || 0) - (right[i] || 0);
		if (diff !== 0) {
			return diff;
		}
	}
	return 0;
}

/** 依赖拓扑排序（同 Android 的「自动修复加载顺序」）：被依赖者在前，其余保持原相对顺序。 */
function fixLoadOrder(settings, mods) {
	const modSettings = modSettingsOf(settings);
	const byId = new Map(mods.map(mod => [mod.id, mod]));
	const current = modSettings.mod_list.filter(item => item && isLocalSource(item.source)).map(item => item.id).filter(id => byId.has(id));
	for (const mod of mods) {
		if (!current.includes(mod.id)) {
			current.push(mod.id);
		}
	}
	const result = [];
	const visiting = new Set();
	const visit = id => {
		if (result.includes(id) || visiting.has(id) || !byId.has(id)) {
			return;
		}
		visiting.add(id);
		for (const dependency of byId.get(id).dependencies) {
			visit(dependency.id);
		}
		visiting.delete(id);
		result.push(id);
	};
	current.forEach(visit);
	const others = modSettings.mod_list.filter(item => !(item && isLocalSource(item.source)));
	modSettings.mod_list = [
		...result.map(id => ({ id, source: MOD_SOURCE, is_enabled: !isDisabled(settings, byId.get(id)) })),
		...others,
	];
}

function isInside(root, target) {
	const relative = path.relative(path.resolve(root), path.resolve(target));
	return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

/** 删除一个 MOD：独占子目录就删整个目录，否则只删同名 json/dll/pck。 */
function deleteMod(modsDir, mod) {
	const dir = mod.directory;
	if (!isInside(modsDir, mod.manifestPath)) {
		throw new Error('mod is outside the mods directory');
	}
	const others = scanManifests(modsDir).filter(other => other.id !== mod.id && (other.directory === dir || isInside(dir, other.directory)));
	if (dir !== path.resolve(modsDir) && isInside(modsDir, dir) && others.length === 0) {
		fs.rmSync(dir, { recursive: true, force: true });
		return;
	}
	const names = new Set([mod.manifestName]);
	for (const base of new Set([mod.id, mod.pckName])) {
		names.add(`${base}.json`);
		names.add(`${base}.dll`);
		names.add(`${base}.pck`);
	}
	for (const name of names) {
		const file = path.join(dir, name);
		if (isSafeModBaseName(name) && fs.existsSync(file) && fs.statSync(file).isFile()) {
			fs.rmSync(file, { force: true });
		}
	}
}

/** 原版只认 <ModId>.json；导入时给 mod_manifest.json 生成同目录别名（同 Android）。 */
function addManifestAliases(root) {
	for (const mod of scanManifests(root)) {
		if (mod.manifestName.toLowerCase() !== 'mod_manifest.json') {
			continue;
		}
		const alias = path.join(mod.directory, `${mod.id}.json`);
		if (!fs.existsSync(alias)) {
			const json = JSON.parse(fs.readFileSync(mod.manifestPath, 'utf8').replace(/^﻿/, ''));
			json.launcher_generated_manifest_alias = true;
			fs.writeFileSync(alias, JSON.stringify(json, null, 2), 'utf8');
		}
	}
}

/**
 * 导入第一步：解包到 staging，解析 manifest，算出目标目录、同 ID 冲突与会被覆盖的文件。
 * 用户确认后再调用 commitImport；什么都不确认就 cancelImport。
 */
async function prepareImport(stagingRoot, modsDir, source) {
	const token = crypto.randomUUID();
	const work = path.join(stagingRoot, token);
	const content = path.join(work, 'content');
	fs.mkdirSync(content, { recursive: true });
	try {
		const stat = fs.statSync(source);
		if (stat.isDirectory()) {
			fs.cpSync(source, path.join(content, path.basename(source)), { recursive: true, verbatimSymlinks: true, filter: from => !fs.lstatSync(from).isSymbolicLink() });
		} else if (source.toLowerCase().endsWith('.zip')) {
			await extractZip(source, content);
		} else {
			throw new Error('unsupported import source');
		}
		const found = scanManifests(content);
		if (found.length === 0) {
			throw new Error('no_manifest');
		}
		addManifestAliases(content);
		// 只有一个顶层目录时把它当作 MOD 目录；文件散在根部时以第一个 MOD id 建目录。
		const top = fs.readdirSync(content, { withFileTypes: true }).filter(e => !e.name.startsWith('__MACOSX'));
		let payloadRoot = content;
		let folderName = found[0].id;
		if (top.length === 1 && top[0].isDirectory()) {
			payloadRoot = path.join(content, top[0].name);
			folderName = top[0].name;
		}
		const installed = fs.existsSync(modsDir) ? scanManifests(modsDir) : [];
		const incoming = scanManifests(payloadRoot);
		const conflicts = installed.filter(mod => incoming.some(inc => inc.id === mod.id));
		const target = path.join(modsDir, folderName);
		const replacedDirs = new Set(conflicts.map(mod => path.resolve(mod.directory)));
		const overwrites = listFiles(payloadRoot)
			.map(file => path.join(target, file))
			.filter(file => fs.existsSync(file) && ![...replacedDirs].some(dir => isInside(dir, file)))
			.map(file => path.relative(modsDir, file).split(path.sep).join('/'));
		const plan = { token, work, payloadRoot, target, modsDir, conflicts, incoming };
		pendingImports.set(token, plan);
		return {
			token,
			folder: path.relative(modsDir, target).split(path.sep).join('/'),
			incoming: incoming.map(mod => ({ id: mod.id, name: mod.name, version: mod.version, author: mod.author })),
			conflicts: conflicts.map(mod => ({ id: mod.id, name: mod.name, version: mod.version, author: mod.author, relativePath: mod.relativePath })),
			overwrites,
		};
	} catch (error) {
		fs.rmSync(work, { recursive: true, force: true });
		throw error;
	}
}

function commitImport(token) {
	const plan = pendingImports.get(token);
	if (!plan) {
		throw new Error('import expired');
	}
	pendingImports.delete(token);
	try {
		fs.mkdirSync(plan.modsDir, { recursive: true });
		for (const mod of plan.conflicts) {
			deleteMod(plan.modsDir, mod);
		}
		fs.cpSync(plan.payloadRoot, plan.target, { recursive: true, force: true });
		return plan.incoming.map(mod => mod.id);
	} finally {
		fs.rmSync(plan.work, { recursive: true, force: true });
	}
}

function cancelImport(token) {
	const plan = pendingImports.get(token);
	if (plan) {
		pendingImports.delete(token);
		fs.rmSync(plan.work, { recursive: true, force: true });
	}
}

module.exports = {
	isSafeModBaseName,
	scanManifests,
	describeMods,
	setDisabled,
	removeFromList,
	fixLoadOrder,
	deleteMod,
	prepareImport,
	commitImport,
	cancelImport,
	compareVersions,
	modSettingsOf,
};
