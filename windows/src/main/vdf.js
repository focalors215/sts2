'use strict';

/** 极简 Valve KeyValues (VDF/ACF) 解析：只支持带引号的键值与嵌套块，足够读取 libraryfolders.vdf / appmanifest。 */
function parseVdf(text) {
	const root = {};
	const stack = [root];
	let i = 0;
	const tokens = [];
	while (i < text.length) {
		const ch = text[i];
		if (ch === '"') {
			let value = '';
			i++;
			while (i < text.length && text[i] !== '"') {
				if (text[i] === '\\' && i + 1 < text.length) {
					i++;
					value += text[i] === 'n' ? '\n' : text[i];
				} else {
					value += text[i];
				}
				i++;
			}
			i++;
			tokens.push({ type: 'string', value });
		} else if (ch === '{' || ch === '}') {
			tokens.push({ type: ch });
			i++;
		} else if (ch === '/' && text[i + 1] === '/') {
			while (i < text.length && text[i] !== '\n') {
				i++;
			}
		} else {
			i++;
		}
	}
	for (let t = 0; t < tokens.length; t++) {
		const token = tokens[t];
		const current = stack[stack.length - 1];
		if (token.type === '}') {
			if (stack.length > 1) {
				stack.pop();
			}
			continue;
		}
		if (token.type !== 'string') {
			continue;
		}
		const next = tokens[t + 1];
		if (next && next.type === '{') {
			const child = {};
			current[token.value] = child;
			stack.push(child);
			t++;
		} else if (next && next.type === 'string') {
			current[token.value] = next.value;
			t++;
		}
	}
	return root;
}

/** 大小写不敏感地取子键（Steam 文件里的键名大小写并不统一）。 */
function getKey(object, key) {
	if (!object || typeof object !== 'object') {
		return undefined;
	}
	const lower = key.toLowerCase();
	for (const name of Object.keys(object)) {
		if (name.toLowerCase() === lower) {
			return object[name];
		}
	}
	return undefined;
}

module.exports = { parseVdf, getKey };
