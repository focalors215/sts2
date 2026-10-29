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
console.log(`shared assets copied to ${path.relative(process.cwd(), out) || out}`);
