'use strict';

/*
 * 文件浏览 / 文本编辑（对齐 Android FileBrowserActivity / TextEditorActivity）：只允许访问几个根目录
 * （游戏存档、启动器数据、当前游戏 MOD 目录）之内的文件，渲染进程传 rootId + 相对路径，主进程解析并检查不越界、
 * 不跟随符号链接。文本文件（≤ 2 MiB、UTF-8）可编辑保存：先写临时文件再改名，首次修改留一份 .launcher-backup。
 */
const fs = require('fs');
const path = require('path');

const MAX_TEXT_BYTES = 2 * 1024 * 1024;
const TEXT_EXTENSIONS = new Set(['.save', '.json', '.txt', '.log', '.cfg', '.ini', '.toml', '.run', '.md', '.xml', '.csv', '.backup', '.tres', '.gd']);
const PROTECTED = /(^|\/)secrets\.json$/i;

function normalizeRelative(relative) {
	const value = String(relative || '').replace(/\\/g, '/').split('/').filter(part => part && part !== '.');
	if (value.some(part => part === '..' || /[\u0000-\u001f:]/.test(part))) {
		throw new Error('files_bad_path');
	}
	return value.join('/');
}

/** 解析 root + relative，确认在根目录内且路径上没有符号链接。 */
function resolve(roots, rootId, relative) {
	const root = roots.find(item => item.id === rootId);
	if (!root) throw new Error('files_bad_root');
	const clean = normalizeRelative(relative);
	const full = path.resolve(root.path, clean);
	const base = path.resolve(root.path);
	if (full !== base && !full.startsWith(base + path.sep)) throw new Error('files_bad_path');
	let current = base;
	for (const part of clean ? clean.split('/') : []) {
		current = path.join(current, part);
		try {
			if (fs.lstatSync(current).isSymbolicLink()) throw new Error('files_bad_path');
		} catch (error) {
			if (error.code === 'ENOENT') break;
			throw error;
		}
	}
	return { root, full, relative: clean };
}

function isTextFile(name) {
	return TEXT_EXTENSIONS.has(path.extname(name).toLowerCase()) || /\.save\.backup$/i.test(name);
}

function list(roots, rootId, relative) {
	const { full, relative: clean } = resolve(roots, rootId, relative);
	let entries = [];
	try {
		entries = fs.readdirSync(full, { withFileTypes: true });
	} catch (error) {
		if (error.code === 'ENOENT') return { relative: clean, entries: [], missing: true };
		throw error;
	}
	return {
		relative: clean,
		entries: entries.filter(entry => !entry.isSymbolicLink()).map(entry => {
			let stat = null;
			try {
				stat = fs.statSync(path.join(full, entry.name));
			} catch (error) {
				stat = null; // 列目录期间被删除。
			}
			return { name: entry.name, dir: entry.isDirectory(), size: stat ? stat.size : 0, mtimeMs: stat ? stat.mtimeMs : 0, text: entry.isFile() && isTextFile(entry.name) };
		}).sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1)),
	};
}

function readText(roots, rootId, relative) {
	const { full, relative: clean } = resolve(roots, rootId, relative);
	if (PROTECTED.test(clean)) throw new Error('files_protected');
	const stat = fs.statSync(full);
	if (!stat.isFile()) throw new Error('files_not_file');
	if (stat.size > MAX_TEXT_BYTES) throw new Error('files_too_large');
	const buffer = fs.readFileSync(full);
	if (buffer.includes(0)) throw new Error('files_binary');
	return { text: buffer.toString('utf8').replace(/^﻿/, ''), mtimeMs: stat.mtimeMs, size: stat.size };
}

/** 保存文本；expectedMtimeMs 不符说明文件在编辑期间被改过（如游戏写回），拒绝覆盖。 */
function writeText(roots, rootId, relative, text, expectedMtimeMs) {
	const { full, relative: clean } = resolve(roots, rootId, relative);
	if (PROTECTED.test(clean)) throw new Error('files_protected');
	if (Buffer.byteLength(String(text), 'utf8') > MAX_TEXT_BYTES) throw new Error('files_too_large');
	const stat = fs.statSync(full);
	if (expectedMtimeMs && Math.abs(stat.mtimeMs - expectedMtimeMs) > 1) throw new Error('files_changed');
	if (/\.(json|save)$/i.test(full)) {
		try {
			JSON.parse(String(text));
		} catch (error) {
			const wrapped = new Error('files_bad_json');
			wrapped.cause = error;
			throw wrapped;
		}
	}
	const backup = `${full}.launcher-backup`;
	if (!fs.existsSync(backup)) fs.copyFileSync(full, backup);
	const temp = `${full}.${process.pid}.tmp`;
	fs.writeFileSync(temp, String(text), 'utf8');
	fs.renameSync(temp, full);
	return { mtimeMs: fs.statSync(full).mtimeMs };
}

module.exports = { MAX_TEXT_BYTES, resolve, list, readText, writeText, isTextFile };
