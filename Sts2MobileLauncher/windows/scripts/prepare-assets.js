'use strict';
// 启动器插画、图标与 Material Symbols 字体只在仓库里保留一份（Android 资源目录），
// Windows 启动器构建/运行前复制到 ignored 的 assets/generated/。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const out = path.resolve(__dirname, '..', 'assets', 'generated');
const copies = [
	['android/res/drawable-nodpi/launcher_home.jpg', 'launcher_home.jpg'],
	['android/res/font/material_symbols_rounded.ttf', 'material_symbols_rounded.ttf'],
	['doc/images/icon.png', 'icon.png'],
];

fs.mkdirSync(out, { recursive: true });
for (const [from, to] of copies) {
	const source = path.join(root, from);
	if (!fs.existsSync(source)) {
		console.error(`missing shared asset: ${from}`);
		process.exit(1);
	}
	fs.copyFileSync(source, path.join(out, to));
}

// 联机小屋服务器（与 Android BuildConfig.FRP_* 同源）：环境变量优先，否则读仓库根目录 .env；不入库。
function readDotEnv(file) {
	const values = {};
	if (!fs.existsSync(file)) {
		return values;
	}
	for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
		const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
		if (match) {
			values[match[1]] = match[2].replace(/^(["'])(.*)\1$/, '$2');
		}
	}
	return values;
}
const dotEnv = readDotEnv(path.join(root, '.env'));
const env = name => process.env[name] !== undefined ? process.env[name] : dotEnv[name] || '';
const onlineFile = path.join(out, 'online.json');
// 公开发行包不应泄露共享 FRP 令牌；仅本机显式选择私有构建时写入。
if (process.env.STS2_EMBED_FRP_TOKEN === '1' && env('STS2_FRP_SERVER')) {
	fs.writeFileSync(onlineFile, JSON.stringify({ server: env('STS2_FRP_SERVER'), serverPort: Number.parseInt(env('STS2_FRP_SERVER_PORT'), 10) || 7000, token: env('STS2_FRP_TOKEN') }));
} else {
	fs.rmSync(onlineFile, { force: true });
	console.warn('Online rooms are disabled in this build; LAN direct connection remains available.');
}
console.log(`shared assets copied to ${path.relative(process.cwd(), out) || out}`);
