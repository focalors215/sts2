'use strict';

/* Steam 创意工坊（对齐 Android SteamWorkshopActivity）：浏览（热门 / 最新发布 / 最近更新 / 最多订阅 +
 * 时间筛选）、按 ID / 链接打开、详情（截图、前置 MOD）、安装到 mods/、已下载与检查更新。
 * PC 上安装来源是 Steam 客户端已订阅下载的内容，或条目自带的旧式直链。 */
ui.workshop = {
	view: 'browse',
	query: '',
	sort: 'trend',
	days: 7,
	page: 1,
	items: [],
	hasNext: false,
	loading: false,
	loaded: false,
	error: '',
	detail: null,
	detailLoading: false,
	local: null,
	updates: new Set(),
	progress: null,
};

const WORKSHOP_SORTS = ['trend', 'mostrecent', 'lastupdated', 'totaluniquesubscribers'];
const WORKSHOP_DAYS = [7, 30, 90, 180, 365, -1];

function workshopRef(text) {
	const value = String(text || '').trim();
	if (/^\d{4,20}$/.test(value)) return value;
	const match = /[?&]id=(\d{4,20})/.exec(value);
	return match ? match[1] : '';
}

async function loadWorkshopPage(reset) {
	const state = ui.workshop;
	if (state.loading) return;
	if (reset) {
		state.page = 1;
		state.items = [];
	}
	state.loading = true;
	state.error = '';
	render();
	try {
		const result = await api.workshopBrowse({ query: state.query, page: state.page, pageSize: 30, sort: state.sort, days: state.days });
		const seen = new Set(state.items.map(item => item.id));
		state.items.push(...result.items.filter(item => !seen.has(item.id)));
		state.hasNext = result.hasNext;
		state.page += 1;
	} catch (error) {
		state.error = formatError(error);
		logUi('W', `创意工坊浏览失败: ${state.error}`);
	} finally {
		state.loading = false;
		state.loaded = true;
		if (ui.tab === 'workshop') render();
	}
}

async function loadWorkshopLocal() {
	try {
		ui.workshop.local = await api.workshopLocal();
	} catch (error) {
		toast(formatError(error), true);
		ui.workshop.local = { steamContent: [], library: [] };
	}
	if (ui.tab === 'workshop') render();
}

async function openWorkshopDetail(ref) {
	const state = ui.workshop;
	state.detailLoading = true;
	state.detail = { id: ref, title: `Workshop ${ref}`, screenshots: [], required: [] };
	render();
	try {
		state.detail = await api.workshopItem(ref);
	} catch (error) {
		state.detail = null;
		toast(formatError(error), true);
	} finally {
		state.detailLoading = false;
		if (ui.tab === 'workshop') render();
	}
}

function workshopInstalled(id) {
	const local = ui.workshop.local;
	return local ? local.library.find(entry => entry.id === id && entry.present) : null;
}

function workshopInSteam(id) {
	const local = ui.workshop.local;
	return !!(local && local.steamContent.some(entry => entry.id === id));
}

function formatDate(seconds) {
	return seconds ? new Date(seconds * 1000).toLocaleDateString() : '';
}

function buildWorkshopPage(inner) {
	const state = ui.workshop;
	if (!state.local) loadWorkshopLocal();
	inner.append(h('div', { class: 'page-header' },
		h('div', { class: 'row' }, h('button', { class: 'icon-btn', title: t('back'), 'aria-label': t('back'), onclick: () => (state.detail ? (state.detail = null, render()) : openTab('mods')) }, icon('arrow_back')),
			pageTitle(t('nav_workshop'), t('tagline_workshop'))),
		h('div', { class: 'segmented', role: 'tablist' },
			['browse', 'downloaded'].map(view => h('button', { class: state.view === view && !state.detail ? 'selected' : '', role: 'tab', onclick: () => { state.view = view; state.detail = null; render(); } },
				view === 'browse' ? t('workshop_browse') : t('workshop_downloaded_count', { count: state.local ? state.local.library.length : 0 }))))));
	if (state.detail) {
		buildWorkshopDetail(inner);
	} else if (state.view === 'downloaded') {
		buildWorkshopDownloaded(inner);
	} else {
		buildWorkshopBrowse(inner);
	}
}

function buildWorkshopBrowse(inner) {
	const state = ui.workshop;
	if (!state.loaded && !state.loading) loadWorkshopPage(true);
	const search = h('input', { type: 'search', placeholder: t('workshop_search'), value: state.query, 'aria-label': t('workshop_search') });
	search.addEventListener('keydown', event => {
		if (event.key !== 'Enter') return;
		const ref = workshopRef(search.value);
		if (ref) {
			openWorkshopDetail(ref);
		} else {
			state.query = search.value;
			loadWorkshopPage(true);
		}
	});
	inner.append(h('label', { class: 'search' }, icon('search'), search));
	inner.append(h('div', { class: 'chip-row' },
		WORKSHOP_SORTS.map(sort => h('button', { class: `chip${state.sort === sort ? ' selected' : ''}`, onclick: () => { state.sort = sort; loadWorkshopPage(true); } }, t(`workshop_sort_${sort}`)))));
	inner.append(h('div', { class: 'chip-row' },
		WORKSHOP_DAYS.map(days => h('button', { class: `chip${state.days === days ? ' selected' : ''}`, onclick: () => { state.days = days; loadWorkshopPage(true); } }, t(`workshop_days_${days < 0 ? 'all' : days}`)))));
	inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', {}, t('workshop_pc_notice'))));
	if (state.error) {
		inner.append(h('div', { class: 'card compact notice warn' }, icon('cloud_off'), h('span', { class: 'grow' }, state.error),
			h('button', { class: 'btn secondary small', onclick: () => loadWorkshopPage(true) }, icon('refresh'), t('retry'))));
	}
	const grid = h('div', { class: 'workshop-grid' });
	for (const item of state.items) {
		grid.append(workshopCard(item));
	}
	inner.append(grid);
	if (state.loading) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
	} else if (state.loaded && !state.items.length && !state.error) {
		inner.append(h('div', { class: 'empty' }, window.mascot.mascotRow(56), t('workshop_empty')));
	} else if (state.hasNext) {
		inner.append(h('div', { class: 'row', style: { justifyContent: 'center' } }, h('button', { class: 'btn secondary small', onclick: () => loadWorkshopPage(false) }, icon('expand_more'), t('workshop_more'))));
	}
}

function workshopCard(item) {
	const installed = workshopInstalled(item.id);
	return h('button', { class: 'workshop-card', onclick: () => openWorkshopDetail(item.id) },
		h('div', { class: 'workshop-thumb', style: item.previewUrl ? { backgroundImage: `url("${item.previewUrl.replace(/"/g, '%22')}")` } : {} }, item.previewUrl ? null : icon('image')),
		h('div', { class: 'workshop-card-body' },
			h('div', { class: 'mod-name ellipsis' }, item.title),
			h('div', { class: 'mod-meta ellipsis' }, [item.author, item.size ? formatBytes(item.size) : '', formatDate(item.timeUpdated)].filter(Boolean).join(' · ')),
			installed ? h('span', { class: 'pill fish' }, icon('check'), t('workshop_installed')) : workshopInSteam(item.id) ? h('span', { class: 'pill' }, icon('cloud_done'), t('workshop_in_steam')) : null));
}

function buildWorkshopDetail(inner) {
	const state = ui.workshop;
	const item = state.detail;
	if (state.detailLoading) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	const installed = workshopInstalled(item.id);
	const inSteam = workshopInSteam(item.id);
	const card = h('div', { class: 'card workshop-detail' },
		h('div', { class: 'hero-name' }, item.title),
		h('div', { class: 'mod-meta' }, [`ID ${item.id}`, item.size ? formatBytes(item.size) : '', item.timeUpdated ? t('workshop_updated', { date: formatDate(item.timeUpdated) }) : '', item.subscriptions ? t('workshop_subs', { count: item.subscriptions }) : ''].filter(Boolean).join(' · ')));
	if (item.tags && item.tags.length) {
		card.append(h('div', { class: 'chip-row' }, item.tags.map(tag => h('span', { class: 'pill' }, tag))));
	}
	if (item.screenshots && item.screenshots.length) {
		card.append(h('div', { class: 'workshop-shots' }, item.screenshots.map(url => h('button', { class: 'workshop-shot', style: { backgroundImage: `url("${url.replace(/"/g, '%22')}")` }, 'aria-label': t('workshop_view_image'), onclick: () => showWorkshopImage(url) }))));
	}
	card.append(h('div', { class: 'workshop-desc' }, item.description || t('mod_desc_none')));
	if (item.required && item.required.length) {
		card.append(h('h2', { class: 'section-heading' }, t('workshop_required')));
		for (const dep of item.required) {
			const depInstalled = workshopInstalled(dep.id);
			card.append(h('div', { class: 'row' }, icon(depInstalled ? 'check_circle' : 'error', depInstalled ? '' : 'warn-icon'),
				h('button', { class: 'link grow', onclick: () => openWorkshopDetail(dep.id) }, dep.title),
				h('span', { class: 'muted' }, depInstalled ? t('workshop_installed') : t('workshop_dep_missing'))));
		}
	}
	card.append(h('div', { class: 'notice soft' }, icon('info'), h('span', {}, inSteam || item.fileUrl ? t('workshop_ready_to_install') : t('workshop_subscribe_hint'))));
	card.append(h('div', { class: 'actions' },
		h('button', { class: 'btn ghost small', onclick: () => run(() => api.openExternal(`https://steamcommunity.com/sharedfiles/filedetails/?id=${item.id}`)) }, icon('open_in_new'), t('workshop_open_web')),
		h('button', { class: 'btn secondary small', onclick: () => run(() => api.workshopSubscribe(item.id), t('workshop_subscribe_opened')) }, icon('add_task'), t('workshop_subscribe')),
		h('button', { class: 'btn primary small', disabled: !inSteam && !item.fileUrl, onclick: () => installWorkshopItem(item) }, icon('download'), installed ? t('workshop_reinstall') : t('workshop_install'))));
	inner.append(card);
}

function showWorkshopImage(url) {
	modal((box, close) => {
		box.classList.add('image-viewer');
		box.append(h('img', { src: url, alt: '', onclick: () => close() }),
			h('div', { class: 'actions' }, h('button', { class: 'btn ghost small', onclick: () => run(() => api.openExternal(url)) }, icon('open_in_new'), t('workshop_open_image')),
				h('button', { class: 'btn primary small', onclick: () => close() }, t('close'))));
	});
}

async function installWorkshopItem(item) {
	const missing = (item.required || []).filter(dep => !workshopInstalled(dep.id));
	if (missing.length && !await confirmDialog(t('workshop_missing_deps_title'), t('workshop_missing_deps', { names: missing.map(dep => dep.title).join('\n') }), t('workshop_install_anyway'))) {
		return;
	}
	let plan;
	try {
		toast(t('workshop_preparing'));
		plan = await api.workshopPrepareInstall(item.id);
	} catch (error) {
		toast(formatError(error), true);
		return;
	}
	if (await importPlanDialog(plan)) {
		await run(() => api.workshopCommitInstall(plan.token), ids => t('imported', { names: ids.join(', ') }));
		await loadWorkshopLocal();
	} else {
		api.workshopCancelInstall(plan.token).catch(error => logUi('W', '取消创意工坊安装失败', error));
	}
}

function buildWorkshopDownloaded(inner) {
	const state = ui.workshop;
	const local = state.local;
	inner.append(h('div', { class: 'chip-row' },
		h('button', { class: 'btn secondary small', onclick: checkWorkshopUpdates }, icon('update'), t('workshop_check_updates')),
		h('button', { class: 'chip', onclick: () => { state.local = null; render(); } }, icon('refresh'), t('refresh'))));
	if (!local) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	const list = h('div', { class: 'mod-list' });
	if (!local.library.length) {
		list.append(h('div', { class: 'empty' }, t('workshop_downloaded_empty')));
	}
	for (const entry of local.library) {
		const update = state.updates.has(entry.id);
		list.append(h('div', { class: `mod-card${entry.present ? '' : ' disabled'}` }, h('div', { class: 'mod-head' },
			icon(update ? 'upgrade' : entry.present ? 'extension' : 'folder_off', 'muted'),
			h('button', { class: 'link grow', style: { textAlign: 'left' }, onclick: () => openWorkshopDetail(entry.id) },
				h('div', { class: 'mod-name ellipsis' }, entry.title || entry.id),
				h('div', { class: 'mod-meta ellipsis' }, [`ID ${entry.id}`, (entry.modIds || []).join(', '), entry.present ? '' : t('workshop_files_gone')].filter(Boolean).join(' · '))),
			update ? h('span', { class: 'pill cat' }, t('workshop_has_update')) : null,
			h('button', { class: 'icon-btn', title: t('delete'), 'aria-label': t('delete'), onclick: () => forgetWorkshopItem(entry) }, icon('delete')))));
	}
	inner.append(list);
	const extra = local.steamContent.filter(entry => !local.library.some(item => item.id === entry.id));
	if (extra.length) {
		inner.append(h('h2', { class: 'section-heading' }, t('workshop_steam_content')), h('div', { class: 'setting-desc' }, t('workshop_steam_content_desc')));
		const steamList = h('div', { class: 'mod-list' });
		for (const entry of extra) {
			steamList.append(h('div', { class: 'mod-card' }, h('div', { class: 'mod-head' }, icon('cloud_done', 'muted'),
				h('button', { class: 'link grow', style: { textAlign: 'left' }, onclick: () => openWorkshopDetail(entry.id) }, h('div', { class: 'mod-name' }, `Workshop ${entry.id}`)),
				h('button', { class: 'btn primary small', onclick: () => installWorkshopItem({ id: entry.id, required: [] }) }, icon('download'), t('workshop_install')))));
		}
		inner.append(steamList);
	}
}

async function checkWorkshopUpdates() {
	try {
		const ids = await api.workshopCheckUpdates();
		ui.workshop.updates = new Set(ids);
		toast(ids.length ? t('workshop_updates_found', { count: ids.length }) : t('workshop_no_updates'));
	} catch (error) {
		toast(formatError(error), true);
	}
	render();
}

async function forgetWorkshopItem(entry) {
	const choice = await modal((box, close) => {
		box.append(h('h2', {}, t('workshop_forget_title')), h('div', { class: 'body' }, t('workshop_forget_body', { name: entry.title || entry.id })),
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(null) }, t('cancel')),
				h('button', { class: 'btn secondary small', onclick: () => close('record') }, t('workshop_forget_record')),
				h('button', { class: 'btn danger small', onclick: () => close('files') }, t('workshop_forget_files'))));
	});
	if (choice) {
		await run(() => api.workshopForget(entry.id, choice === 'files'));
		await loadWorkshopLocal();
	}
}

api.onWorkshopProgress(info => {
	if (info.total) {
		toast(t('workshop_downloading', { percent: Math.round(info.received / info.total * 100) }));
	}
});

registerPage('workshop', { build: buildWorkshopPage, parent: 'mods', onOpen: () => { ui.workshop.local = null; } });
