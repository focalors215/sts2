'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const llm = require('../src/main/llm');
const { SecretStore } = require('../src/main/secrets');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-llm-test-'));
}

test('normalizes the chat completions endpoint like Android LlmConfig', () => {
	const ep = baseUrl => llm.endpoint({ baseUrl });
	assert.strictEqual(ep('https://api.example.com'), 'https://api.example.com/v1/chat/completions');
	assert.strictEqual(ep('https://api.example.com/v1/'), 'https://api.example.com/v1/chat/completions');
	assert.strictEqual(ep('http://127.0.0.1:1234/x/chat/completions'), 'http://127.0.0.1:1234/x/chat/completions');
	for (const bad of ['ftp://a', 'https://u:p@a/v1', 'https://a/v1?k=1', 'https://a/#x', 'nope']) {
		assert.throws(() => ep(bad), /Base URL/);
	}
	assert.throws(() => llm.validateConfig({ baseUrl: 'https://a', model: '', apiKey: '' }), /Model ID/);
	assert.throws(() => llm.validateConfig({ baseUrl: 'https://a', model: 'm', apiKey: 'a\nb' }), /换行/);
});

test('log tools read pages and search literally within authorised files only', () => {
	const dir = tempDir();
	const file = path.join(dir, 'launcher.log');
	const lines = Array.from({ length: 100 }, (_, i) => (i === 49 ? 'ERROR boom here' : `line ${i + 1}`));
	fs.writeFileSync(file, `${lines.join('\n')}\n`);
	const tools = new llm.LogTools([{ path: file, name: 'launcher.log' }]);
	assert.deepStrictEqual(tools.metadata(), [{ file_id: 'log_1', name: 'launcher.log', lines: 100, size: fs.statSync(file).size }]);
	const page = tools.execute('read_lines', { file_id: 'log_1', start_line: 1, end_line: 100 });
	assert.strictEqual(page.lines.length, 60);
	assert.strictEqual(page.truncated, true);
	assert.strictEqual(page.next_line, 61);
	const search = tools.execute('search_logs', { file_id: 'log_1', keyword: 'boom' });
	assert.deepStrictEqual(search.lines.map(l => [l.line, l.match]), [[49, false], [50, true], [51, false]]);
	assert.strictEqual(tools.execute('search_logs', { file_id: 'log_1', keyword: 'BOOM' }).lines.length, 0, 'case sensitive');
	assert.match(tools.execute('read_lines', { file_id: '/etc/passwd', start_line: 1, end_line: 2 }).error, /授权/);
	assert.match(tools.execute('read_lines', { file_id: 'log_1', start_line: 1, end_line: 2, path: 'x' }).error, /未定义/);
	assert.match(tools.execute('exec', {}).error, /未知/);
	assert.match(tools.execute('read_lines', { file_id: 'log_1', start_line: 5, end_line: 2 }).error, /闭区间/);
	assert.strictEqual(tools.summary('read_lines', page), '读取 log_1：第 1–60 行（可继续分页）');
	fs.appendFileSync(file, 'more\n');
	assert.match(tools.execute('read_lines', { file_id: 'log_1', start_line: 1, end_line: 2 }).error, /发生变化/);
	assert.throws(() => new llm.LogTools([]), /1–3/);
});

test('chat session runs tool calls and rolls back on failure', async () => {
	const dir = tempDir();
	const file = path.join(dir, 'godot.log');
	fs.writeFileSync(file, 'ok\nERROR: crash in Foo\n');
	const tools = new llm.LogTools([{ path: file, name: 'godot.log' }]);
	const replies = [
		{ role: 'assistant', content: null, tool_calls: [{ id: 'c1', type: 'function', function: { name: 'search_logs', arguments: JSON.stringify({ file_id: 'log_1', keyword: 'ERROR' }) } }] },
		{ role: 'assistant', content: '原因在 log_1:2。' },
	];
	const seen = [];
	const session = new llm.ChatSession(async messages => {
		seen.push(messages.length);
		return replies.shift();
	}, tools, tools.systemPrompt());
	const progress = [];
	const result = await session.ask('为什么崩溃？', null, summary => progress.push(summary));
	assert.deepStrictEqual(result, { text: '原因在 log_1:2。', budgetReached: false });
	assert.deepStrictEqual(progress, ['搜索 log_1：第 1–2 行']);
	assert.deepStrictEqual(session.messages.map(m => m.role), ['system', 'user', 'assistant', 'tool', 'assistant']);
	assert.strictEqual(JSON.parse(session.messages[3].content).lines[1].text, 'ERROR: crash in Foo');

	const failing = new llm.ChatSession(async () => ({ role: 'assistant', content: '' }), tools, 'sys');
	await assert.rejects(failing.ask('q'), /未返回分析/);
	assert.strictEqual(failing.messages.length, 1, 'rolled back to the system prompt');
	const controller = new AbortController();
	controller.abort();
	await assert.rejects(new llm.ChatSession(async () => ({}), tools, 'sys').ask('q', controller.signal), /已停止/);
});

test('complete() posts a chat request without following redirects', async () => {
	let request;
	const fakeFetch = async (url, init) => {
		request = { url, init };
		const body = JSON.stringify({ choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'hi' } }] });
		return new Response(body, { status: 200 });
	};
	const message = await llm.complete({ baseUrl: 'https://a.test', apiKey: 'sk-test', model: 'm', reasoningEffort: 'low' }, [{ role: 'user', content: 'x' }], [], null, fakeFetch);
	assert.deepStrictEqual(message, { role: 'assistant', content: 'hi' });
	assert.strictEqual(request.url, 'https://a.test/v1/chat/completions');
	assert.strictEqual(request.init.redirect, 'manual');
	assert.strictEqual(request.init.headers.Authorization, 'Bearer sk-test');
	assert.strictEqual(JSON.parse(request.init.body).reasoning_effort, 'low');
	await assert.rejects(llm.complete({ baseUrl: 'https://a.test', model: 'm', apiKey: '' }, [], [], null, async () => new Response('secret body', { status: 401 })), /HTTP 401/);
});

test('secret store encrypts values and refuses plaintext fallback', () => {
	const file = path.join(tempDir(), 'secrets.json');
	const cipher = { available: true, isEncryptionAvailable() { return this.available; }, encryptString: text => Buffer.from(`enc:${text}`), decryptString: buffer => buffer.toString().replace(/^enc:/, '') };
	const store = new SecretStore(file, cipher);
	assert.strictEqual(store.get('ai.apiKey'), '');
	store.set('ai.apiKey', 'sk-123456');
	assert.ok(!fs.readFileSync(file, 'utf8').includes('sk-123456'));
	assert.strictEqual(store.get('ai.apiKey'), 'sk-123456');
	assert.strictEqual(store.has('ai.apiKey'), true);
	cipher.available = false;
	assert.throws(() => store.set('webdav.password', 'pw-123'), /secret_store_unavailable/);
	store.set('ai.apiKey', '');
	assert.strictEqual(store.has('ai.apiKey'), false);
});
