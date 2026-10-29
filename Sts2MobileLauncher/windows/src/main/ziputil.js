'use strict';

const fs = require('fs');
const path = require('path');
const yauzl = require('yauzl');
const yazl = require('yazl');

const MAX_ENTRIES = 20000;
const MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024;

/** 归一化 zip 内条目名（兼容反斜杠），拒绝绝对路径、盘符与 ..（Zip Slip）。 */
function safeEntryName(rawName) {
	const name = rawName.replace(/\\/g, '/');
	if (name.startsWith('/') || /^[a-zA-Z]:/.test(name)) {
		return null;
	}
	const parts = name.split('/').filter(part => part !== '' && part !== '.');
	if (parts.some(part => part === '..' || /[\u0000-\u001f]/.test(part))) {
		return null;
	}
	return parts.join('/');
}

/** 安全解压到 destination（必须是新建的空目录）。返回解压出的相对路径列表。 */
function extractZip(zipFile, destination) {
	const root = path.resolve(destination);
	return new Promise((resolve, reject) => {
		yauzl.open(zipFile, { lazyEntries: true, decodeStrings: true, strictFileNames: false }, (openError, zip) => {
			if (openError) {
				reject(openError);
				return;
			}
			const written = [];
			const seen = new Set();
			let total = 0;
			let failed = false;
			const fail = error => {
				if (!failed) {
					failed = true;
					zip.close();
					reject(error);
				}
			};
			zip.on('error', fail);
			zip.on('end', () => {
				if (!failed) {
					resolve(written);
				}
			});
			zip.on('entry', entry => {
				if (written.length >= MAX_ENTRIES) {
					fail(new Error('zip has too many entries'));
					return;
				}
				const name = safeEntryName(entry.fileName);
				if (name === null) {
					fail(new Error(`unsafe zip entry: ${entry.fileName}`));
					return;
				}
				if (name === '') {
					zip.readEntry();
					return;
				}
				const target = path.resolve(root, name);
				if (target !== root && !target.startsWith(root + path.sep)) {
					fail(new Error(`unsafe zip entry: ${entry.fileName}`));
					return;
				}
				const key = name.toLowerCase();
				if (/\/$/.test(entry.fileName.replace(/\\/g, '/'))) {
					fs.mkdirSync(target, { recursive: true });
					zip.readEntry();
					return;
				}
				if (seen.has(key)) {
					fail(new Error(`duplicate zip entry: ${entry.fileName}`));
					return;
				}
				seen.add(key);
				total += entry.uncompressedSize;
				if (total > MAX_TOTAL_BYTES) {
					fail(new Error('zip is too large'));
					return;
				}
				fs.mkdirSync(path.dirname(target), { recursive: true });
				zip.openReadStream(entry, (streamError, stream) => {
					if (streamError) {
						fail(streamError);
						return;
					}
					const out = fs.createWriteStream(target, { flags: 'wx' });
					out.on('error', fail);
					stream.on('error', fail);
					out.on('close', () => {
						written.push(name);
						if (!failed) {
							zip.readEntry();
						}
					});
					stream.pipe(out);
				});
			});
			zip.readEntry();
		});
	});
}

function listFiles(directory, base = directory, out = []) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isSymbolicLink()) {
			continue;
		}
		if (entry.isDirectory()) {
			listFiles(full, base, out);
		} else if (entry.isFile()) {
			out.push(path.relative(base, full).split(path.sep).join('/'));
		}
	}
	return out;
}

/** 把整个目录打成 zip，额外写入 manifest 条目（JSON）。先写 .part，完成后再改名。 */
function zipDirectory(directory, zipFile, manifest) {
	const files = fs.existsSync(directory) ? listFiles(directory) : [];
	const part = `${zipFile}.part`;
	return new Promise((resolve, reject) => {
		const zip = new yazl.ZipFile();
		for (const file of files) {
			zip.addFile(path.join(directory, file), `files/${file}`);
		}
		zip.addBuffer(Buffer.from(JSON.stringify({ ...manifest, files }, null, 2), 'utf8'), 'snapshot.json');
		const out = fs.createWriteStream(part);
		out.on('error', reject);
		out.on('close', () => {
			try {
				fs.renameSync(part, zipFile);
				resolve(files);
			} catch (error) {
				reject(error);
			}
		});
		zip.outputStream.pipe(out);
		zip.end();
	});
}

module.exports = { extractZip, zipDirectory, listFiles, safeEntryName };
