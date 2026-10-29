'use strict';

// 原创矢量吉祥物（纯代码绘制），与 Android CottageTheme.MascotView 同一套 100×100 坐标。
(function () {
	const INK_BROWN = '#5A3A2E';
	const S = 2.6;
	const THIN = 1.8;

	const poly = (fill, stroke, width, ...xy) => {
		const points = [];
		for (let i = 0; i < xy.length; i += 2) {
			points.push(`${xy[i]},${xy[i + 1]}`);
		}
		return `<polygon points="${points.join(' ')}" fill="${fill || 'none'}"${stroke ? ` stroke="${stroke}" stroke-width="${width}"` : ''}/>`;
	};
	const ellipse = (fill, stroke, width, x, y, w, h) => `<ellipse cx="${x + w / 2}" cy="${y + h / 2}" rx="${w / 2}" ry="${h / 2}" fill="${fill || 'none'}"${stroke ? ` stroke="${stroke}" stroke-width="${width}"` : ''}/>`;
	const circle = (fill, stroke, width, x, y, r) => ellipse(fill, stroke, width, x - r, y - r, 2 * r, 2 * r);
	const line = (x1, y1, x2, y2) => `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${INK_BROWN}" stroke-width="${THIN}"/>`;
	const path = (d, width) => `<path d="${d}" fill="none" stroke="${INK_BROWN}" stroke-width="${width}"/>`;

	// 呆猫：奶白脸、放空的小圆眼、八字分脸花纹。
	function cat() {
		const fur = '#FFF8EE';
		const patch = '#8C6B5A';
		const pink = '#FFB3B8';
		const parts = [
			poly(fur, INK_BROWN, S, 14, 44, 16, 8, 44, 28),
			poly(fur, INK_BROWN, S, 86, 44, 84, 8, 56, 28),
			poly(pink, null, 0, 20, 38, 21, 17, 36, 30),
			poly(pink, null, 0, 80, 38, 79, 17, 64, 30),
			ellipse(fur, INK_BROWN, S, 8, 26, 84, 66),
			poly(patch, null, 0, 46, 29, 54, 29, 41, 52, 29, 52),
			poly(patch, null, 0, 54, 29, 46, 29, 59, 52, 71, 52),
			circle(INK_BROWN, null, 0, 35, 64, 3.8),
			circle(INK_BROWN, null, 0, 65, 64, 3.8),
			circle('rgba(255,179,184,0.7)', null, 0, 23, 73, 5.5),
			circle('rgba(255,179,184,0.7)', null, 0, 77, 73, 5.5),
			path('M44 74 Q46 79 50 77 Q54 79 56 74', S),
		];
		for (const side of [-1, 1]) {
			for (let i = 0; i < 2; i++) {
				parts.push(line(50 + side * 34, 70 + i * 5, 50 + side * 47, 66 + i * 10));
			}
		}
		return parts.join('');
	}

	// 小鲨鱼：圆圆的蓝灰身体、大眼睛、带小尖牙的笑。
	function shark() {
		const body = '#8CC8E3';
		const belly = '#F4FBFF';
		const parts = [
			poly(body, INK_BROWN, S, 88, 56, 99, 38, 99, 74),
			poly(body, INK_BROWN, S, 42, 36, 55, 5, 66, 36),
			ellipse(body, INK_BROWN, S, 6, 28, 88, 58),
			ellipse(belly, null, 0, 20, 60, 56, 22),
		];
		for (let i = 0; i < 3; i++) {
			parts.push(line(74 + i * 4, 50, 72 + i * 4, 58));
		}
		parts.push(
			circle('#FFFFFF', INK_BROWN, S, 32, 52, 7),
			circle('#FFFFFF', INK_BROWN, S, 58, 52, 7),
			circle(INK_BROWN, null, 0, 33, 53, 3.8),
			circle(INK_BROWN, null, 0, 59, 53, 3.8),
			circle('#FFFFFF', null, 0, 34.5, 51.2, 1.3),
			circle('#FFFFFF', null, 0, 60.5, 51.2, 1.3),
			circle('rgba(255,179,184,0.75)', null, 0, 21, 65, 4.5),
			circle('rgba(255,179,184,0.75)', null, 0, 69, 65, 4.5),
			path('M36 67 Q45 77 54 67', S),
			poly('#FFFFFF', null, 0, 39, 69, 43, 69, 41, 74),
			poly('#FFFFFF', null, 0, 47, 69, 51, 69, 49, 74),
		);
		return parts.join('');
	}

	function svg(content, size) {
		return `<svg viewBox="0 0 100 100" width="${size}" height="${size}" stroke-linejoin="round" stroke-linecap="round" aria-hidden="true">${content}</svg>`;
	}

	/** 喵喵零（小猫）和小鱼（小鲨鱼）并排。 */
	function mascotRow(size) {
		const row = document.createElement('div');
		row.className = 'mascots';
		row.setAttribute('aria-hidden', 'true');
		row.innerHTML = svg(cat(), size) + svg(shark(), size);
		return row;
	}

	/** 小猫爪：一个掌垫 + 四个趾垫（同 Android PawDrawable）。 */
	function paw(color, size) {
		const toe = (cx, cy) => `<ellipse cx="${cx}" cy="${cy}" rx="2.3" ry="2.8"/>`;
		return `<svg class="paw" viewBox="0 0 24 24" width="${size}" height="${size}" fill="${color}" aria-hidden="true"><ellipse cx="12" cy="16.25" rx="5.5" ry="4.75"/>${toe(4.5, 9.5)}${toe(9, 5.5)}${toe(15, 5.5)}${toe(19.5, 9.5)}</svg>`;
	}

	window.mascot = { mascotRow, paw };
})();
