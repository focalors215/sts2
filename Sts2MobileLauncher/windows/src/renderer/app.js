'use strict';

/* 主题：喵喵零和小鱼的小屋（与 Android GameSettingsActivity / iPad LauncherViewController 同一套布局）。
 * 宽屏为左侧插画侧栏 + 内容，「回到小屋」显示整幅插画主页；窄屏为顶部胶囊标签 + 内容。 */
const { t } = window.i18n;
const api = window.launcher;

const ART_WIDTH = 1536;
const ART_HEIGHT = 1024;
const BRAND_RECT = { x: 36, y: 64, w: 576, h: 308 };
const POSTCARD_RECT = { x: 560, y: 372, w: 715, h: 380 };
// 主页插画里已画好的按钮位置（与 Android CottageHomeStage / iPad 一致）。
const HOTSPOTS = [
	{ key: 'saves', x: 52, y: 405, w: 313, h: 102 },
	{ key: 'mods', x: 52, y: 522, w: 313, h: 103 },
	{ key: 'network', x: 52, y: 640, w: 313, h: 102 },
	{ key: 'settings', x: 52, y: 757, w: 103, h: 98 },
	{ key: 'start', x: 488, y: 788, w: 590, h: 147 },
];
// 插画里需要完整可见的纵向范围（logo 顶部到「开始游戏」底部）。
const CONTENT_TOP = 40;
const CONTENT_BOTTOM = 960;
const STEAM_APP_ID = '2868840';
const REPO_URL = 'https://github.com/ModinMobileSTS/Sts2MobileLauncher';

const ui = {
	state: null,
	tab: 'home',
	settingsSegment: 'display',
	modSearch: '',
	modFilter: 'all',
	openMods: new Set(),
	layoutKey: '',
	busy: false,
};

// ---------- 小工具 ----------
function h(tag, attrs, ...children) {
	const el = document.createElement(tag);
	for (const [key, value] of Object.entries(attrs || {})) {
		if (value === undefined || value === null || value === false) {
			continue;
		}
		if (key === 'class') {
			el.className = value;
		} else if (key.startsWith('on')) {
			el.addEventListener(key.slice(2), value);
		} else if (key === 'style' && typeof value === 'object') {
			Object.assign(el.style, value);
		} else if (value === true) {
			el.setAttribute(key, '');
		} else {
			el.setAttribute(key, value);
		}
	}
	for (const child of children.flat()) {
		if (child === null || child === undefined || child === false) {
			continue;
		}
		el.append(child instanceof Node ? child : document.createTextNode(String(child)));
	}
	return el;
}

const icon = (name, cls) => h('span', { class: `ms${cls ? ` ${cls}` : ''}`, 'aria-hidden': 'true' }, name);

function html(markup) {
	const template = document.createElement('template');
	template.innerHTML = markup;
	return template.content.firstElementChild;
}

function outlined(text, cls) {
	return h('h1', { class: `outlined ${cls || ''}`, 'data-text': text }, text);
}

function pageTitle(title, tagline) {
	return h('div', { class: 'title-stack' }, outlined(title, 'page-title'), tagline ? h('span', { class: 'tagline' }, `—  ${tagline}  —`) : null);
}

/** 插画裁片：用背景定位从整张插画里取出 logo / 明信片（file:// 下不能用 canvas 裁图）。 */
function artCard(key, label, cls) {
	const rect = key === 'brand' ? BRAND_RECT : POSTCARD_RECT;
	return h('div', {
		class: `art-card ${cls || ''}`,
		role: 'img',
		'aria-label': label,
		style: {
			aspectRatio: `${rect.w} / ${rect.h}`,
			backgroundImage: 'var(--art)',
			backgroundSize: `${ART_WIDTH / rect.w * 100}% ${ART_HEIGHT / rect.h * 100}%`,
			backgroundPosition: `${rect.x / (ART_WIDTH - rect.w) * 100}% ${rect.y / (ART_HEIGHT - rect.h) * 100}%`,
		},
	});
}

function switchControl(checked, onChange, disabled, label) {
	const input = h('input', { type: 'checkbox', role: 'switch', 'aria-label': label, disabled });
	input.checked = !!checked;
	input.addEventListener('change', () => onChange(input.checked));
	input.addEventListener('click', event => event.stopPropagation());
	return h('label', { class: 'switch', onclick: event => event.stopPropagation() }, input, h('span', { class: 'track' }), h('span', { class: 'thumb' }));
}

function formatError(error) {
	const message = error && error.message ? error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : String(error);
	const known = { no_profile: 'err_no_profile', game_not_ready: 'err_game_not_ready', game_running: 'err_game_running', no_settings_save: 'err_no_settings_save', no_manifest: 'no_manifest' };
	return known[message] ? t(known[message]) : t('error', { message });
}

let toastTimer = null;
function toast(message, isError) {
	const el = document.getElementById('toast');
	el.textContent = message;
	el.classList.toggle('error', !!isError);
	el.classList.add('show');
	clearTimeout(toastTimer);
	toastTimer = setTimeout(() => el.classList.remove('show'), isError ? 5000 : 2600);
}

async function run(task, success) {
	if (ui.busy) {
		return undefined;
	}
	ui.busy = true;
	try {
		const result = await task();
		if (success) {
			toast(typeof success === 'function' ? success(result) : success);
		}
		await refresh();
		return result;
	} catch (error) {
		toast(formatError(error), true);
		await refresh();
		return undefined;
	} finally {
		ui.busy = false;
	}
}

// ---------- 弹窗 ----------
function modal(build) {
	return new Promise(resolve => {
		const root = document.getElementById('modal-root');
		const previous = document.activeElement;
		const close = value => {
			scrim.remove();
			document.removeEventListener('keydown', onKey);
			if (previous && previous.focus) {
				previous.focus();
			}
			resolve(value);
		};
		const onKey = event => {
			if (event.key === 'Escape') {
				close(undefined);
			}
		};
		const box = h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' });
		build(box, close);
		const scrim = h('div', { class: 'modal-scrim', onmousedown: event => { if (event.target === scrim) close(undefined); } }, box);
		root.append(scrim);
		document.addEventListener('keydown', onKey);
		const focusable = box.querySelector('.choice.selected, input, button.primary, button');
		if (focusable) {
			focusable.focus();
		}
	});
}

function confirmDialog(title, body, okLabel, danger) {
	return modal((box, close) => {
		box.append(
			h('h2', {}, title),
			h('div', { class: 'body' }, body),
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(false) }, t('cancel')),
				h('button', { class: `btn ${danger ? 'danger' : 'primary'} small`, onclick: () => close(true) }, okLabel || t('ok'))),
		);
	});
}

/** 单选列表（Android 设置页的 Bottom Sheet 单选，桌面上改为居中弹窗）。 */
function choiceDialog(title, options, current) {
	return modal((box, close) => {
		box.append(h('h2', {}, title));
		for (const option of options) {
			const selected = option.value === current;
			box.append(h('button', { class: `choice${selected ? ' selected' : ''}`, onclick: () => close(option.value) },
				icon(selected ? 'radio_button_checked' : 'radio_button_unchecked'),
				h('span', { class: 'grow' }, option.label)));
		}
		box.append(h('div', { class: 'actions' }, h('button', { class: 'btn ghost small', onclick: () => close(undefined) }, t('cancel'))));
	});
}

// ---------- 状态 ----------
function currentProfile() {
	const state = ui.state;
	return state && state.profiles.find(p => p.id === state.selectedProfileId) || null;
}

function isWide() {
	return window.innerWidth >= 720 && window.innerWidth > window.innerHeight;
}

/** 主页插画只在横向且足够宽时显示（同 iPad：宽高比至少 1.25），否则主页显示游戏管理页。 */
function showsHomeScene() {
	return isWide() && window.innerWidth / window.innerHeight >= 1.25;
}

async function refresh() {
	ui.state = await api.state();
	window.i18n.setLanguage(ui.state.settings.language);
	render();
}

function openTab(tab) {
	ui.tab = tab;
	api.setLastTab(tab).catch(() => {});
	render();
	const page = document.querySelector('.page');
	if (page) {
		page.scrollTop = 0;
	}
}

// ---------- 外壳 ----------
function render() {
	const app = document.getElementById('app');
	const stage = document.getElementById('home-stage');
	const backdrop = document.getElementById('backdrop');
	const state = ui.state;
	document.querySelectorAll('.welcome').forEach(el => el.remove());
	if (!state.welcomeDone && state.profiles.length === 0) {
		app.replaceChildren();
		stage.hidden = true;
		backdrop.hidden = false;
		document.body.append(buildWelcome());
		return;
	}
	const wide = isWide();
	let tab = ui.tab;
	if (tab === 'dashboard' && !wide) {
		tab = 'home';
	}
	const scene = tab === 'home' && showsHomeScene();
	stage.hidden = !scene;
	app.hidden = scene;
	backdrop.hidden = scene;
	if (scene) {
		buildHomeStage(stage);
		return;
	}
	const previousScroll = document.querySelector('.page') ? document.querySelector('.page').scrollTop : 0;
	const sameTab = app.dataset.tab === tab;
	app.className = wide ? 'wide' : 'narrow';
	app.dataset.tab = tab;
	const content = h('div', { class: 'content' }, buildPage(tab, wide));
	app.replaceChildren(wide ? buildSidebar(tab) : buildTabs(tab), content);
	if (sameTab) {
		content.firstElementChild.scrollTop = previousScroll;
	}
}

function buildSidebar(tab) {
	const items = [
		['home', 'nav_home', 'home'],
		['dashboard', 'nav_dashboard', 'stadia_controller'],
		['mods', 'nav_mods', 'extension'],
		['versions', 'nav_versions', 'layers'],
		['settings', 'nav_settings', 'settings'],
		['about', 'nav_about', 'info'],
	];
	const sidebar = h('nav', { class: 'sidebar' }, artCard('brand', t('theme_name')));
	for (const [key, label, glyph] of items) {
		sidebar.append(h('button', { class: `nav-button${tab === key ? ' selected' : ''}`, 'aria-current': tab === key ? 'page' : null, onclick: () => openTab(key) }, icon(glyph), label ? t(label) : ''));
	}
	if (window.innerHeight >= 650) {
		sidebar.append(artCard('postcard', t('postcard'), 'postcard'));
	}
	return sidebar;
}

function buildTabs(tab) {
	const items = [['home', 'tab_home'], ['mods', 'tab_mods'], ['versions', 'tab_versions'], ['settings', 'tab_settings'], ['about', 'tab_about']];
	const tabs = h('div', { class: 'tabs', role: 'tablist' });
	for (const [key, label] of items) {
		tabs.append(h('button', { class: `tab${tab === key ? ' selected' : ''}`, role: 'tab', 'aria-selected': tab === key ? 'true' : 'false', onclick: () => openTab(key) }, t(label)));
	}
	return h('div', { class: 'tabs-holder' }, tabs);
}

function buildPage(tab, wide) {
	const inner = h('div', { class: 'page-inner' });
	if (tab === 'mods') {
		buildModsPage(inner);
	} else if (tab === 'versions') {
		buildVersionsPage(inner);
	} else if (tab === 'settings') {
		buildSettingsPage(inner);
	} else if (tab === 'about') {
		buildAboutPage(inner);
	} else {
		buildDashboard(inner, wide);
	}
	return h('div', { class: 'page' }, inner);
}

// ---------- 插画主页 ----------
function homeStatus() {
	const profile = currentProfile();
	if (!profile) {
		return { text: t('status_missing'), action: () => openTab('versions') };
	}
	if (!profile.info.ready) {
		return { text: t('status_broken'), action: () => openTab('versions') };
	}
	return null;
}

function buildHomeStage(stage) {
	const width = window.innerWidth;
	const height = window.innerHeight;
	// 优先铺满；若铺满会把插画里的按钮裁出屏幕，就按高度让按钮区完整可见。
	const fill = Math.max(width / ART_WIDTH, height / ART_HEIGHT);
	const scale = Math.min(fill, height / (CONTENT_BOTTOM - CONTENT_TOP));
	const artWidth = ART_WIDTH * scale;
	const artHeight = ART_HEIGHT * scale;
	const originX = Math.round((width - artWidth) / 2);
	let originY = Math.round((height - artHeight) / 2);
	if (artHeight > height) {
		const centered = height / 2 - (CONTENT_TOP + CONTENT_BOTTOM) / 2 * scale;
		originY = Math.round(Math.max(height - artHeight, Math.min(0, centered)));
	}
	const labels = t('hotspots');
	const children = [
		h('div', { class: 'stage-backdrop', 'aria-hidden': 'true' }),
		h('div', { class: 'stage-art', 'aria-hidden': 'true', style: { left: `${originX}px`, top: `${originY}px`, width: `${artWidth}px`, height: `${artHeight}px` } }),
	];
	let startRect = null;
	HOTSPOTS.forEach((spot, index) => {
		const rect = { left: originX + spot.x * scale, top: originY + spot.y * scale, width: spot.w * scale, height: spot.h * scale };
		// 圆角与插画里的按钮一致：开始游戏是胶囊，左侧菜单是大圆角方块。
		const radius = spot.key === 'start' ? rect.height / 2 : 52 * scale;
		if (spot.key === 'start') {
			startRect = rect;
		}
		children.push(h('button', {
			class: 'hotspot',
			'aria-label': labels[index],
			title: labels[index],
			style: { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px`, borderRadius: `${radius}px` },
			onclick: () => onHotspot(spot.key),
		}));
	});
	const status = homeStatus();
	if (status && startRect) {
		const pill = h('button', { class: 'status-pill', onclick: status.action }, `${status.text}  ›`);
		pill.style.left = `${startRect.left + startRect.width / 2}px`;
		pill.style.maxWidth = `${Math.round(640 * scale)}px`;
		pill.style.fontSize = `${Math.max(12, Math.min(16, 15 * scale * 1.4))}px`;
		children.push(pill);
		requestAnimationFrame(() => {
			pill.style.top = `${startRect.top - pill.offsetHeight - 10 * scale}px`;
		});
	}
	stage.replaceChildren(...children);
}

function onHotspot(key) {
	if (key === 'start') {
		launchGame();
	} else if (key === 'saves') {
		ui.settingsSegment = 'saves';
		openTab('settings');
	} else if (key === 'mods') {
		openTab('mods');
	} else if (key === 'network') {
		ui.settingsSegment = 'system';
		openTab('settings');
	} else {
		openTab('settings');
	}
}

async function launchGame() {
	const profile = currentProfile();
	if (!profile) {
		toast(t('err_no_profile'), true);
		openTab('versions');
		return;
	}
	toast(t('launching'));
	await run(() => api.launch(), result => (result.via === 'steam' ? t('launched_steam') : t('launched_exe')));
}

// ---------- 游戏管理 ----------
function buildDashboard(inner, wide) {
	const state = ui.state;
	const profile = currentProfile();
	const header = h('div', { class: 'page-header' });
	header.append(wide ? pageTitle(t('nav_dashboard'), t('tagline_dashboard')) : artCard('brand', t('theme_name'), 'brand-inline'));
	if (!wide) {
		header.firstChild.style.width = '210px';
	}
	header.append(h('button', { class: 'chip', onclick: () => openTab('versions') }, icon(profile && profile.source === 'steam' ? 'cloud' : 'folder'),
		profile ? t('profile_chip', { name: profile.name || profile.gameDir }) : t('profile_chip_none')));
	inner.append(header);

	const ready = !!profile && profile.info.ready;
	const hero = h('div', { class: 'card hero' }, artCard('postcard', t('postcard')));
	const names = h('div', { class: 'grow' }, h('div', { class: 'hero-name' }, t('theme_name')), h('div', { class: 'hero-sub' }, t('hero_subtitle')));
	hero.append(h('div', { class: 'row' }, names, window.mascot.mascotRow(44)));
	let line;
	if (!profile) {
		line = t('no_profile_line');
	} else if (profile.info.ready) {
		line = t('ready_line', { version: profile.info.version || profile.name });
	} else {
		line = t('not_ready_line');
	}
	hero.append(h('div', { class: `status-line ${profile && profile.info.ready ? 'ok' : 'bad'}` }, icon(profile && profile.info.ready ? 'check_circle' : 'error'), line));
	const start = h('button', { class: 'btn primary', disabled: !ready, onclick: launchGame }, ready ? t('start_game') : t('launch_disabled'));
	start.insertAdjacentHTML('beforeend', window.mascot.paw(ready ? '#FFC76B' : 'rgba(255,199,107,0.47)', 20));
	hero.append(start);

	const mods = state.mods;
	const total = mods ? mods.mods.length : 0;
	const enabled = mods ? mods.mods.filter(m => m.enabled).length : 0;
	const statusRow = h('div', { class: 'status-row' },
		statusCard('extension', t('mods_card'), total ? t('mods_value', { enabled, total }) : t('mods_none'), mods && mods.modsEnabled ? t('mods_on') : t('mods_off'), () => openTab('mods')),
		statusCard('save', t('saves_card'), state.saves.account ? t('saves_value', { count: state.saves.snapshots.length }) : t('saves_none'),
			state.saves.account ? t('saves_account', { id: shortAccount(state.saves.account) }) : state.saves.root, () => { ui.settingsSegment = 'saves'; openTab('settings'); }));

	const maintenance = [
		['folder_open', 'act_open_game', () => run(() => api.open('game'))],
		['extension', 'act_open_mods', () => run(() => api.open('mods'))],
		['save', 'act_open_saves', () => run(() => api.open('saves'))],
		['photo_camera', 'act_snapshot', () => run(() => api.createSnapshot(), t('snapshot_created'))],
	];
	const advanced = [
		['layers', 'act_profiles', () => openTab('versions')],
		['verified', 'act_validate', () => run(() => api.openExternal(`steam://validate/${STEAM_APP_ID}`))],
		['description', 'act_logs', () => run(() => api.open('logs'))],
		['inventory_2', 'act_data', () => run(() => api.open('data'))],
	];
	const columns = wide ? 2 : 4;
	const rightItems = [
		statusRow,
		h('h2', { class: 'section-heading' }, t('maintenance')),
		actionGrid(maintenance, columns),
		h('h2', { class: 'section-heading' }, t('advanced')),
		actionGrid(advanced, columns),
	];
	if (wide && window.innerWidth >= 1000) {
		inner.append(h('div', { class: 'dashboard-columns' }, h('div', {}, hero), h('div', {}, rightItems)));
	} else {
		inner.append(hero, ...rightItems.map(item => item));
		rightItems[2].className = 'action-grid cols-4';
		rightItems[4].className = 'action-grid cols-4';
	}
}

function shortAccount(id) {
	return id.length > 24 ? `…${id.slice(-22)}` : id;
}

function statusCard(glyph, title, value, sub, onClick) {
	return h('button', { class: 'status-card', onclick: onClick },
		icon(glyph, 'watermark'),
		h('div', { class: 'row' }, h('span', { class: 'badge' }, icon(glyph)), h('span', { class: 'soft' }, title)),
		h('div', { class: 'value' }, value),
		h('div', { class: 'sub ellipsis' }, sub));
}

function actionGrid(actions, columns) {
	return h('div', { class: `action-grid cols-${columns}` }, actions.map(([glyph, label, fn]) => h('button', { class: 'action', onclick: fn }, icon(glyph), t(label))));
}

// ---------- 本地 MOD ----------
function warningText(warning) {
	const text = t(`w_${warning.kind}`, { target: '\u0000' });
	const [before, after] = text.split('\u0000');
	return after === undefined ? h('span', {}, text) : h('span', {}, before, h('b', {}, warning.target), after);
}

function buildModsPage(inner) {
	const state = ui.state;
	const mods = state.mods;
	const problems = mods ? mods.mods.filter(m => m.warnings.length) : [];
	const header = h('div', { class: 'page-header' }, pageTitle(t('nav_mods'), t('tagline_mods')));
	if (problems.length) {
		header.append(h('button', { class: 'warn-badge', onclick: showProblems }, icon('warning'), String(problems.length)));
	}
	inner.append(header);
	if (!mods) {
		inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', {}, t('mods_no_profile'))),
			h('div', {}, h('button', { class: 'btn secondary small', onclick: () => openTab('versions') }, icon('layers'), t('nav_versions'))));
		return;
	}
	inner.append(h('div', { class: 'setting' }, icon('power_settings_new', 'lead'),
		h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('mods_master')), h('div', { class: 'setting-desc' }, t('mods_master_desc'))),
		switchControl(mods.modsEnabled, value => run(() => api.setModsMaster(value)), !mods.settingsAvailable, t('mods_master'))));
	if (!mods.settingsAvailable) {
		inner.append(h('div', { class: 'card compact notice warn' }, icon('warning'), h('span', {}, t('mods_no_settings'))));
	}
	const search = h('input', { type: 'search', placeholder: t('mods_search'), value: ui.modSearch, 'aria-label': t('mods_search') });
	search.addEventListener('input', () => {
		ui.modSearch = search.value;
		renderModList(list);
	});
	inner.append(h('div', { class: 'row wrap' }, h('label', { class: 'search' }, icon('search'), search)));
	const filters = [['all', 'filter_all'], ['enabled', 'filter_enabled'], ['disabled', 'filter_disabled'], ['problems', 'filter_problems']];
	inner.append(h('div', { class: 'chip-row' },
		h('button', { class: 'chip', onclick: () => importMod('zip') }, icon('folder_zip'), t('import_zip')),
		h('button', { class: 'chip', onclick: () => importMod('folder') }, icon('create_new_folder'), t('import_folder')),
		h('button', { class: 'chip', onclick: () => run(() => api.open('mods')) }, icon('folder_open'), t('open_folder')),
		h('button', { class: 'chip', onclick: () => run(() => Promise.resolve()) }, icon('refresh'), t('refresh')),
		filters.map(([key, label]) => h('button', { class: `chip${ui.modFilter === key ? ' selected' : ''}`, onclick: () => { ui.modFilter = key; render(); } }, t(label)))));
	const list = h('div', { class: 'mod-list' });
	renderModList(list);
	inner.append(list);
}

function renderModList(list) {
	const mods = ui.state.mods;
	const query = ui.modSearch.trim().toLowerCase();
	const visible = mods.mods.filter(mod => {
		if (ui.modFilter === 'enabled' && !mod.enabled) return false;
		if (ui.modFilter === 'disabled' && mod.enabled) return false;
		if (ui.modFilter === 'problems' && !mod.warnings.length) return false;
		if (!query) return true;
		return [mod.name, mod.id, mod.author, mod.description, mod.version].join('\n').toLowerCase().includes(query);
	});
	if (!mods.mods.length) {
		list.replaceChildren(h('div', { class: 'empty' }, window.mascot.mascotRow(56), t('mods_empty')));
		return;
	}
	if (!visible.length) {
		list.replaceChildren(h('div', { class: 'empty' }, t('mods_no_match')));
		return;
	}
	list.replaceChildren(...visible.map(modCard));
}

function modCard(mod) {
	const key = `${mod.id}|${mod.relativePath}`;
	const open = ui.openMods.has(key);
	const card = h('div', { class: `mod-card${open ? ' open' : ''}${mod.warnings.length ? ' problem' : ''}${mod.enabled ? '' : ' disabled'}` });
	const meta = [mod.version && `v${mod.version.replace(/^v/i, '')}`, mod.author].filter(Boolean).join(' · ') || mod.id;
	const head = h('div', { class: 'mod-head', role: 'button', tabindex: '0', 'aria-expanded': open ? 'true' : 'false' },
		mod.warnings.length ? icon('warning', 'warn-icon') : icon('extension', 'muted'),
		h('div', { class: 'grow' }, h('div', { class: 'mod-name ellipsis' }, mod.name), h('div', { class: 'mod-meta ellipsis' }, meta)),
		switchControl(mod.enabled, value => run(() => api.setModEnabled(mod.id, value)), !ui.state.mods.settingsAvailable, mod.name),
		icon('expand_more', 'chev'));
	head.querySelector('.warn-icon') && (head.querySelector('.warn-icon').style.color = 'var(--cat)');
	const toggle = () => {
		if (ui.openMods.has(key)) ui.openMods.delete(key); else ui.openMods.add(key);
		card.replaceWith(modCard(mod));
	};
	head.addEventListener('click', toggle);
	head.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); toggle(); } });
	card.append(head);
	if (open) {
		const body = h('div', { class: 'mod-body' }, h('div', {}, mod.description || t('mod_desc_none')));
		body.append(...mod.warnings.map(w => h('div', { class: 'mod-warn' }, icon('warning'), warningText(w))));
		const kv = h('div', { class: 'kv' });
		const add = (k, v) => kv.append(h('span', { class: 'k' }, k), h('span', { class: 'mono' }, v));
		add('ID', mod.id);
		add(t('mod_path'), `mods/${mod.relativePath}`);
		if (mod.author) add(t('mod_author'), mod.author);
		if (mod.dependencies.length) add(t('mod_deps'), mod.dependencies.map(d => d.minVersion ? `${d.id} ≥ ${d.minVersion}` : d.id).join(', '));
		if (mod.minGameVersion) add(t('mod_min_game'), mod.minGameVersion);
		body.append(kv, h('div', { class: 'row', style: { justifyContent: 'flex-end' } },
			h('button', { class: 'btn danger small', onclick: async () => {
				if (await confirmDialog(t('mod_delete_title'), t('mod_delete_body', { name: mod.name }), t('mod_delete'), true)) {
					run(() => api.deleteMod(mod.id, mod.relativePath));
				}
			} }, icon('delete'), t('mod_delete'))));
		card.append(body);
	}
	return card;
}

function showProblems() {
	const mods = ui.state.mods;
	const problems = mods.mods.filter(m => m.warnings.length);
	modal((box, close) => {
		box.append(h('h2', {}, t('problems_title')));
		if (!problems.length) {
			box.append(h('div', { class: 'body' }, t('problems_none')));
		}
		for (const mod of problems) {
			box.append(h('div', { class: 'info-card' },
				h('div', { class: 'mod-name' }, mod.name),
				h('div', { class: 'mod-meta' }, [mod.version, mod.author].filter(Boolean).join(' · ') || mod.id),
				mod.warnings.map(w => h('div', { class: 'mod-warn', style: { marginTop: '6px' } }, icon('warning'), warningText(w)))));
		}
		const actions = h('div', { class: 'actions' });
		if (mods.orderFixable && mods.settingsAvailable) {
			actions.append(h('button', { class: 'btn primary small', onclick: () => { close(); run(() => api.fixModOrder()); } }, icon('sort'), t('problems_fix')));
		}
		actions.append(h('button', { class: 'btn ghost small', onclick: () => close() }, t('close')));
		box.append(actions);
	});
}

async function importMod(kind) {
	let plan;
	try {
		plan = await api.prepareModImport(kind);
	} catch (error) {
		toast(formatError(error), true);
		return;
	}
	if (!plan) {
		return;
	}
	const choice = await modal((box, close) => {
		box.append(h('h2', {}, t('import_title')),
			h('div', { class: 'body' }, t('import_will_install', { folder: plan.folder })),
			h('div', { class: 'info-card' }, plan.incoming.map(m => h('div', {}, h('b', {}, m.name), h('span', { class: 'muted' }, `  ${[m.version, m.author].filter(Boolean).join(' · ')}`)))));
		if (plan.conflicts.length) {
			box.append(h('div', { class: 'notice warn' }, icon('warning'), h('span', {}, t('import_conflict'))),
				h('div', { class: 'info-card' }, plan.conflicts.map(m => h('div', {}, h('b', {}, m.name), h('span', { class: 'mono muted' }, `  mods/${m.relativePath}`)))));
		}
		if (plan.overwrites.length) {
			box.append(h('div', { class: 'notice warn' }, icon('warning'), h('span', {}, t('import_overwrite'))),
				h('ul', { class: 'file-list mono' }, plan.overwrites.slice(0, 50).map(f => h('li', {}, f))));
		}
		const risky = plan.conflicts.length || plan.overwrites.length;
		box.append(h('div', { class: 'actions' },
			h('button', { class: 'btn ghost small', onclick: () => close(false) }, plan.conflicts.length ? t('import_keep_old') : t('cancel')),
			h('button', { class: `btn ${risky ? 'danger' : 'primary'} small`, onclick: () => close(true) },
				plan.conflicts.length ? t('import_use_new') : plan.overwrites.length ? t('import_replace') : t('import_confirm'))));
	});
	if (choice) {
		await run(() => api.commitModImport(plan.token), ids => t('imported', { names: ids.join(', ') }));
	} else {
		api.cancelModImport(plan.token).catch(() => {});
	}
}

// ---------- 版本管理 ----------
function buildVersionsPage(inner) {
	const state = ui.state;
	inner.append(h('div', { class: 'page-header' }, pageTitle(t('nav_versions'), t('tagline_versions'))));
	inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', {}, t('versions_notice'))));
	inner.append(h('div', { class: 'chip-row' },
		h('button', { class: 'btn secondary small', onclick: detectSteam }, icon('travel_explore'), t('detect_steam')),
		h('button', { class: 'btn secondary small', onclick: () => run(() => api.addFolder()) }, icon('create_new_folder'), t('add_folder'))));
	if (!state.profiles.length) {
		inner.append(h('div', { class: 'card empty' }, window.mascot.mascotRow(56), t('profiles_empty')));
		return;
	}
	for (const profile of state.profiles) {
		inner.append(profileCard(profile, profile.id === state.selectedProfileId));
	}
}

async function detectSteam() {
	await run(() => api.detectSteam(), result => (result.found ? t('detect_done', { count: result.found }) : t('detect_none')));
}

function profileCard(profile, selected) {
	const info = profile.info;
	const card = h('div', { class: `card profile-card${selected ? ' selected' : ''}` });
	card.append(h('div', { class: 'row wrap' },
		icon(profile.source === 'steam' ? 'cloud' : 'folder', 'lead'),
		h('div', { class: 'profile-title grow ellipsis' }, profile.name || profile.gameDir),
		selected ? h('span', { class: 'pill cat' }, icon('check'), t('profile_current')) : null,
		info.version ? h('span', { class: 'pill' }, info.version) : null,
		h('span', { class: `pill ${info.ready ? 'fish' : 'bad'}` }, icon(info.ready ? 'check_circle' : 'error'), info.ready ? t('profile_ready') : t('profile_missing', { files: info.missing.join(', ') }))));
	card.firstChild.firstChild.style.color = 'var(--cat)';
	const kv = h('div', { class: 'kv-grid' });
	const add = (k, v, mono) => kv.append(h('span', { class: 'k' }, k), h('span', { class: mono ? 'mono' : '' }, v));
	add(t('profile_path'), profile.gameDir, true);
	add(t('profile_branch'), [profile.source === 'steam' ? t('profile_source_steam') : t('profile_source_manual'), profile.steamBranch || info.branch].filter(Boolean).join(' · '));
	add(t('profile_launch'), profile.launchViaSteam ? t('profile_via_steam') : t('profile_via_exe'));
	if (info.dllSha256) add(t('profile_dll'), `${info.dllSha256.slice(0, 16)}…`, true);
	if (profile.extraArgs) add(t('edit_args'), profile.extraArgs, true);
	card.append(kv);
	card.append(h('div', { class: 'chip-row' },
		selected ? null : h('button', { class: 'btn primary small', onclick: () => run(() => api.selectProfile(profile.id)) }, icon('check'), t('profile_select')),
		h('button', { class: 'chip', onclick: () => editProfile(profile) }, icon('edit'), t('profile_edit')),
		h('button', { class: 'chip', onclick: () => run(() => api.open('game', profile.id)) }, icon('folder_open'), t('profile_open')),
		h('button', { class: 'chip', onclick: async () => {
			if (await confirmDialog(t('remove_title'), t('remove_body', { name: profile.name || profile.gameDir }), t('profile_remove'), true)) {
				run(() => api.removeProfile(profile.id));
			}
		} }, icon('delete'), t('profile_remove'))));
	return card;
}

async function editProfile(profile) {
	const result = await modal((box, close) => {
		const name = h('input', { class: 'text-input', value: profile.name, 'aria-label': t('edit_name') });
		const args = h('input', { class: 'text-input', value: profile.extraArgs, placeholder: t('set_args_placeholder'), 'aria-label': t('edit_args') });
		let viaSteam = profile.launchViaSteam;
		box.append(h('h2', {}, t('edit_title')),
			h('div', { class: 'setting-title' }, t('edit_name')), name,
			h('div', { class: 'row' }, h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('edit_via_steam')), h('div', { class: 'setting-desc' }, t('edit_via_steam_desc'))),
				switchControl(viaSteam, value => { viaSteam = value; }, false, t('edit_via_steam'))),
			h('div', { class: 'setting-title' }, t('edit_args')), args,
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(null) }, t('cancel')),
				h('button', { class: 'btn primary small', onclick: () => close({ name: name.value.trim(), extraArgs: args.value.trim(), launchViaSteam: viaSteam }) }, t('save'))));
	});
	if (result) {
		await run(() => api.updateProfile(profile.id, result));
	}
}

// ---------- 设置 ----------
const OPTIONS = {
	windowMode: ['default', 'fullscreen', 'windowed'].map(v => ({ value: v, label: () => t(`window_${v}`) })),
	renderer: ['default', 'vulkan', 'd3d12', 'opengl3'].map(v => ({ value: v, label: () => t(`renderer_${v}`) })),
	afterLaunch: ['keep', 'minimize', 'close'].map(v => ({ value: v, label: () => t(`after_${v}`) })),
	language: ['auto', 'zh', 'en'].map(v => ({ value: v, label: () => t(`language_${v}`) })),
	logLevel: ['off', 'info', 'debug', 'very_debug'].map(v => ({ value: v, label: () => t(`log_${v}`) })),
	snapshotKeep: [3, 5, 10, 20].map(v => ({ value: v, label: () => String(v) })),
};

function choiceRow(glyph, key, title, desc) {
	const settings = ui.state.settings;
	const options = OPTIONS[key];
	const current = options.find(o => o.value === settings[key]);
	return h('button', {
		class: 'setting clickable',
		onclick: async () => {
			const value = await choiceDialog(title, options.map(o => ({ value: o.value, label: o.label() })), settings[key]);
			if (value !== undefined && value !== settings[key]) {
				run(() => api.updateSettings({ [key]: value }));
			}
		},
	}, icon(glyph, 'lead'),
	h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, title), desc ? h('div', { class: 'setting-desc' }, desc) : null),
	h('span', { class: 'setting-value' }, current ? current.label() : ''), icon('chevron_right', 'muted'));
}

function toggleRow(glyph, key, title, desc) {
	return h('div', { class: 'setting' }, icon(glyph, 'lead'),
		h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, title), desc ? h('div', { class: 'setting-desc' }, desc) : null),
		switchControl(ui.state.settings[key], value => run(() => api.updateSettings({ [key]: value })), false, title));
}

function buildSettingsPage(inner) {
	inner.append(h('div', { class: 'page-header' }, pageTitle(t('nav_settings'), t('tagline_settings'))));
	const segments = [['display', 'seg_display'], ['controls', 'seg_controls'], ['saves', 'seg_saves'], ['system', 'seg_system']];
	inner.append(h('div', { class: 'segmented', role: 'tablist' }, segments.map(([key, label]) =>
		h('button', { class: ui.settingsSegment === key ? 'selected' : '', role: 'tab', 'aria-selected': ui.settingsSegment === key ? 'true' : 'false', onclick: () => { ui.settingsSegment = key; render(); } }, t(label)))));
	const grid = h('div', { class: 'settings-grid' });
	inner.append(grid);
	const segment = ui.settingsSegment;
	if (segment === 'display') {
		grid.append(choiceRow('fullscreen', 'windowMode', t('set_window'), t('set_window_desc')),
			choiceRow('memory', 'renderer', t('set_renderer'), t('set_renderer_desc')));
	} else if (segment === 'controls') {
		grid.append(choiceRow('rocket_launch', 'afterLaunch', t('set_after'), t('set_after_desc')),
			choiceRow('translate', 'language', t('set_language')));
	} else if (segment === 'saves') {
		buildSavesSettings(inner, grid);
	} else {
		buildSystemSettings(inner, grid);
	}
}

function buildSavesSettings(inner, grid) {
	const state = ui.state;
	const settings = state.settings;
	grid.append(h('div', { class: 'setting column' },
		h('div', { class: 'row' }, icon('folder', 'lead'), h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('set_save_root')), h('div', { class: 'setting-desc' }, t('set_save_root_desc')))),
		h('div', { class: 'mono soft' }, state.saves.root),
		h('div', { class: 'chip-row' },
			h('button', { class: 'chip', onclick: () => run(() => api.pickSaveRoot()) }, icon('edit'), t('change')),
			settings.saveRoot ? h('button', { class: 'chip', onclick: () => run(() => api.updateSettings({ saveRoot: '', saveAccount: '' })) }, icon('restart_alt'), t('reset_default')) : null,
			h('button', { class: 'chip', onclick: () => run(() => api.open('saves')) }, icon('folder_open'), t('open')))));
	const accountOptions = [{ value: '', label: t('account_auto') }, ...state.saves.accounts.map(a => ({ value: a.id, label: a.id }))];
	grid.append(h('button', {
		class: 'setting clickable',
		onclick: async () => {
			const value = await choiceDialog(t('set_account'), accountOptions, settings.saveAccount);
			if (value !== undefined) {
				run(() => api.updateSettings({ saveAccount: value }));
			}
		},
	}, icon('person', 'lead'),
	h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('set_account')), h('div', { class: 'setting-desc' }, t('set_account_desc'))),
	h('span', { class: 'setting-value mono' }, state.saves.account ? shortAccount(state.saves.account) : t('account_none')), icon('chevron_right', 'muted')));
	grid.append(toggleRow('photo_camera', 'snapshotBeforeLaunch', t('set_snapshot_launch'), t('set_snapshot_launch_desc')),
		choiceRow('history', 'snapshotKeep', t('set_snapshot_keep'), t('set_snapshot_keep_desc')));

	const list = h('div', { class: 'card compact' });
	if (!state.saves.snapshots.length) {
		list.append(h('div', { class: 'muted' }, t('snapshots_empty')));
	}
	for (const snapshot of state.saves.snapshots) {
		const label = t(`reason_${snapshot.reason}`);
		list.append(h('div', { class: 'snapshot' }, icon('inventory_2', 'muted'),
			h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, new Date(snapshot.mtimeMs).toLocaleString()),
				h('div', { class: 'setting-desc' }, `${label.startsWith('reason_') ? snapshot.reason : label} · ${(snapshot.size / 1024).toFixed(0)} KB`)),
			h('button', { class: 'chip', onclick: async () => {
				if (await confirmDialog(t('restore_title'), t('restore_body', { name: snapshot.name }), t('restore'))) {
					run(() => api.restoreSnapshot(snapshot.name), t('snapshot_restored'));
				}
			} }, icon('restore'), t('restore')),
			h('button', { class: 'icon-btn', title: t('delete'), 'aria-label': t('delete'), onclick: () => run(() => api.deleteSnapshot(snapshot.name)) }, icon('delete'))));
	}
	inner.append(h('div', { class: 'row wrap' }, h('h2', { class: 'section-heading grow' }, t('snapshots')),
		h('button', { class: 'btn secondary small', disabled: !state.saves.account, onclick: () => run(() => api.createSnapshot(), t('snapshot_created')) }, icon('add_a_photo'), t('snapshot_now'))), list);
}

function buildSystemSettings(inner, grid) {
	const settings = ui.state.settings;
	grid.append(choiceRow('description', 'logLevel', t('set_log'), t('set_log_desc')));
	const args = h('input', { class: 'text-input mono', value: settings.extraArgs, placeholder: t('set_args_placeholder'), 'aria-label': t('set_args') });
	args.addEventListener('change', () => run(() => api.updateSettings({ extraArgs: args.value.trim() })));
	grid.append(h('div', { class: 'setting column' },
		h('div', { class: 'row' }, icon('terminal', 'lead'), h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('set_args')), h('div', { class: 'setting-desc' }, t('set_args_desc')))), args));
	grid.append(h('div', { class: 'setting' }, icon('inventory_2', 'lead'),
		h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('set_data')), h('div', { class: 'setting-desc mono' }, ui.state.dataDir)),
		h('button', { class: 'chip', onclick: () => run(() => api.open('data')) }, icon('folder_open'), t('open'))));
	inner.append(h('h2', { class: 'section-heading' }, t('network_title')),
		h('div', { class: 'card compact notice' }, icon('groups'), h('span', {}, t('network_body'))));
}

// ---------- 关于 ----------
function buildAboutPage(inner) {
	inner.append(h('div', { class: 'page-header' }, pageTitle(t('nav_about'), t('tagline_about'))));
	inner.append(h('div', { class: 'card about-hero' }, artCard('brand', t('theme_name')),
		h('div', { class: 'grow', style: { minWidth: '240px' } },
			h('div', { class: 'hero-name' }, t('theme_name')),
			h('div', { class: 'soft', style: { margin: '6px 0 14px' } }, t('about_version', { version: ui.state.appVersion })),
			window.mascot.mascotRow(64))));
	inner.append(h('div', { class: 'card about-text' }, h('p', { style: { marginTop: 0 } }, t('about_body')), h('p', { style: { marginBottom: 0 } }, t('about_note'))));
	inner.append(h('div', {}, h('button', { class: 'btn secondary small', onclick: () => run(() => api.openExternal(REPO_URL)) }, icon('open_in_new'), t('about_repo'))));
}

// ---------- 欢迎 ----------
function buildWelcome() {
	return h('div', { class: 'welcome' }, h('div', { class: 'card' },
		artCard('brand', t('theme_name')),
		outlined(t('welcome_title'), 'page-title'),
		window.mascot.mascotRow(56),
		h('div', { class: 'soft', style: { lineHeight: '1.6' } }, t('welcome_body')),
		h('div', { class: 'btn-col' },
			h('button', { class: 'btn primary', onclick: async () => { await detectSteam(); } }, icon('travel_explore'), t('detect_steam')),
			h('button', { class: 'btn secondary', onclick: () => run(() => api.addFolder()) }, icon('create_new_folder'), t('add_folder')),
			h('button', { class: 'btn ghost', onclick: () => run(() => api.setWelcomeDone()) }, t('welcome_skip')))));
}

// ---------- 启动 ----------
let resizeTimer = null;
window.addEventListener('resize', () => {
	clearTimeout(resizeTimer);
	resizeTimer = setTimeout(() => {
		const key = `${isWide()}|${showsHomeScene()}|${window.innerWidth >= 1000}|${window.innerHeight >= 650}`;
		if (key !== ui.layoutKey || (ui.tab === 'home' && showsHomeScene())) {
			ui.layoutKey = key;
			if (ui.state) {
				render();
			}
		}
	}, 60);
});

document.addEventListener('keydown', event => {
	if (event.key === 'F5') {
		event.preventDefault();
		refresh();
	}
});

api.onGameExited(() => {
	toast(t('game_exited'));
	refresh();
});

(async function boot() {
	ui.state = await api.state();
	window.i18n.setLanguage(ui.state.settings.language);
	ui.tab = ui.state.lastTab || 'home';
	ui.layoutKey = `${isWide()}|${showsHomeScene()}|${window.innerWidth >= 1000}|${window.innerHeight >= 650}`;
	if (ui.state.profiles.length === 0 && ui.state.platform === 'win32' && !ui.state.welcomeDone) {
		try {
			await api.detectSteam();
			ui.state = await api.state();
		} catch (error) {
			// 检测失败就留在欢迎页手动选择。
		}
	}
	document.title = `STS2 · ${t('theme_name')}`;
	render();
})();
