'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Logger, redact, formatLine, localTimestamp, parseLine } = require('../src/main/logger');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-logger-test-'));
}

test('formats lines like the cross-platform spec', () => {
	const date = new Date(2026, 10, 9, 12, 34, 56, 789);
	const stamp = localTimestamp(date);
	assert.match(stamp, /^2026-11-09T12:34:56\.789[+-]\d{2}:\d{2}$/);
	const error = new TypeError('boom');
	const line = formatLine('E', 'online', '创建房间失败: 端口占用', error, date);
	const [first, ...rest] = line.trimEnd().split('\n');
	assert.strictEqual(first, `${stamp} E [online] 创建房间失败: 端口占用 | TypeError: boom`);
	assert.ok(rest.length > 0 && rest.every(l => l.startsWith('    at ')));
	assert.deepStrictEqual(parseLine(first), { time: stamp, level: 'E', tag: 'online', message: '创建房间失败: 端口占用 | TypeError: boom' });
	assert.strictEqual(parseLine('    at foo'), null);
	// 未知标签归到 app；多行消息缩进。
	assert.match(formatLine('I', 'nope', 'a\nb', null, date), /I \[app\] a\n {4}b\n$/);
	assert.match(formatLine('W', 'cloud', 'x', { code: 'ENOENT', message: 'missing', name: 'Error' }, date), /W \[cloud\] x \| Error \[ENOENT\]: missing/);
});

test('redacts registered secrets and common credential shapes', () => {
	assert.strictEqual(redact('token=abc123 and auth.token = "s3cr3t"'), 'token=*** and auth.token = "***"');
	assert.strictEqual(redact('{"password":"hunter2","user":"bob"}'), '{"password":"***","user":"bob"}');
	assert.strictEqual(redact('Authorization: Bearer abcdefghijkl'), 'Authorization: Bearer ***');
	assert.strictEqual(redact('apikey: AAAA-BBBB'), 'apikey: ***');
	assert.strictEqual(redact('GET https://alice:pa55@dav.example/x'), 'GET https://alice:***@dav.example/x');
	assert.strictEqual(redact('frp said: login failed for my-frp-token-xyz', ['my-frp-token-xyz']), 'frp said: login failed for ***');
	assert.strictEqual(redact('nothing secret here'), 'nothing secret here');
});

test('writes, redacts and rotates launcher.log keeping five files', () => {
	const dir = tempDir();
	const logger = new Logger({ dir, maxBytes: 400 });
	logger.addSecret('super-secret-token');
	logger.e('frp', 'login with super-secret-token failed', new Error('token super-secret-token rejected'));
	const text = fs.readFileSync(path.join(dir, 'launcher.log'), 'utf8');
	assert.ok(!text.includes('super-secret-token'));
	assert.match(text, /E \[frp\] login with \*\*\* failed \| Error: token \*\*\* rejected/);
	logger.d('app', 'hidden debug line');
	assert.ok(!fs.readFileSync(path.join(dir, 'launcher.log'), 'utf8').includes('hidden debug line'));
	logger.setDebug(true);
	logger.d('app', 'visible debug line');
	for (let i = 0; i < 60; i++) {
		logger.i('app', `line ${i} ${'x'.repeat(40)}`);
	}
	const names = fs.readdirSync(dir).sort();
	assert.deepStrictEqual(names, ['launcher.1.log', 'launcher.2.log', 'launcher.3.log', 'launcher.4.log', 'launcher.log']);
	for (const name of names) {
		assert.ok(fs.statSync(path.join(dir, name)).size <= 400, `${name} exceeds the limit`);
	}
	assert.match(fs.readFileSync(path.join(dir, 'launcher.log'), 'utf8'), /line 59/);
	assert.strictEqual(logger.files()[0], path.join(dir, 'launcher.log'));
	assert.strictEqual(logger.files().length, 5);
});
