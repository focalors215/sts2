'use strict';

/* Nexus Mods 商店（对齐 Android NexusModsStoreActivity）：保存 Personal API Key 后浏览 / 搜索 / 按 ID 查询、
 * 查看文件并下载导入 mods/。非 Premium 被拒绝下载时，引导到网页「Mod Manager Download」并粘贴 nxm:// 链接。 */
ui.nexus = { config: null, mods: null, loading: false, error: '', query: '', detail: null, detailLoading: false };

async function loadNexus(query) {
	const state = ui.nexus;
	state.loading = true;
	state.error = '';
	render();
	try {
		state.config = state.config || await api.nexusGetConfig();
		if (state.config.hasKey) {
			state.mods = query ? await api.nexusSearch(query) : await api.nexusDiscover();
		}
	} catch (error) {
		state.error = formatError(error);
		state.mods = state.mods || [];
	} finally {
		state.loading = false;
		if (ui.tab === 'nexus') render();
	}
}

function buildNexusPage(inner) {
	const state = ui.nexus;
	if (!state.config && !state.loading) loadNexus('');
	inner.append(h('div', { class: 'page-header' },
		h('div', { class: 'row' }, h('button', { class: 'icon-btn', title: t('back'), 'aria-label': t('back'), onclick: () => (state.detail ? (state.detail = null, render()) : openTab('mods')) }, icon('arrow_back')),
			pageTitle(t('nav_nexus'), t('nexus_tagline')))));
	if (!state.config) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	inner.append(nexusKeyCard());
	if (!state.config.hasKey) {
		return;
	}
	if (state.detail) {
		buildNexusDetail(inner);
		return;
	}
	const search = h('input', { type: 'search', placeholder: t('nexus_search'), value: state.query, 'aria-label': t('nexus_search') });
	search.addEventListener('keydown', event => {
		if (event.key === 'Enter') {
			state.query = search.value;
			loadNexus(search.value.trim());
		}
	});
	inner.append(h('div', { class: 'row wrap' }, h('label', { class: 'search grow' }, icon('search'), search),
		h('button', { class: 'chip', onclick: () => run(() => api.openExternal(`https://www.nexusmods.com/slaythespire2/mods/`)) }, icon('open_in_new'), t('nexus_open_site'))));
	if (state.error) {
		inner.append(h('div', { class: 'card compact notice warn' }, icon('cloud_off'), h('span', {}, state.error)));
	}
	if (state.loading) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	const grid = h('div', { class: 'workshop-grid' });
	for (const mod of state.mods || []) {
		grid.append(h('button', { class: 'workshop-card', onclick: () => openNexusMod(mod.modId) },
			h('div', { class: 'workshop-thumb', style: mod.pictureUrl ? { backgroundImage: `url("${mod.pictureUrl.replace(/"/g, '%22')}")` } : {} }, mod.pictureUrl ? null : icon('image')),
			h('div', { class: 'workshop-card-body' },
				h('div', { class: 'mod-name ellipsis' }, mod.name),
				h('div', { class: 'mod-meta ellipsis' }, [mod.author, mod.version && `v${mod.version.replace(/^v/i, '')}`, mod.downloads ? t('nexus_downloads', { count: mod.downloads }) : ''].filter(Boolean).join(' · ')),
				h('div', { class: 'mod-meta two-lines' }, mod.summary))));
	}
	inner.append(grid);
	if (state.mods && !state.mods.length) {
		inner.append(h('div', { class: 'empty' }, t('nexus_empty')));
	}
}

function nexusKeyCard() {
	const cfg = ui.nexus.config;
	if (cfg.hasKey) {
		return h('div', { class: 'setting' }, icon('key', 'lead'),
			h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('nexus_key_saved', { user: cfg.user || '?' })),
				h('div', { class: 'setting-desc' }, cfg.premium ? t('nexus_premium') : t('nexus_not_premium'))),
			h('button', { class: 'btn ghost small', onclick: () => run(async () => { await api.nexusClearKey(); ui.nexus.config = null; ui.nexus.mods = null; }, t('nexus_key_cleared')) }, t('nexus_clear_key')));
	}
	const input = h('input', { class: 'text-input', type: 'password', autocomplete: 'off', spellcheck: false, placeholder: t('nexus_key_placeholder'), 'aria-label': t('nexus_key_title') });
	const save = () => run(async () => {
		const user = await api.nexusSaveKey(input.value);
		ui.nexus.config = null;
		ui.nexus.mods = null;
		return user;
	}, user => t('nexus_key_valid', { user: user.name }));
	input.addEventListener('keydown', event => { if (event.key === 'Enter') save(); });
	return h('div', { class: 'card compact column-gap' },
		h('div', { class: 'setting-title' }, icon('key'), ' ', t('nexus_key_title')),
		h('div', { class: 'setting-desc' }, t('nexus_key_desc')),
		input,
		h('div', { class: 'actions' },
			h('button', { class: 'btn ghost small', onclick: () => run(() => api.openExternal('https://www.nexusmods.com/users/myaccount?tab=api')) }, icon('open_in_new'), t('nexus_get_key')),
			h('button', { class: 'btn primary small', onclick: save }, icon('lock'), t('nexus_save_key'))));
}

async function openNexusMod(modId) {
	const state = ui.nexus;
	state.detail = { modId, name: `#${modId}`, files: [] };
	state.detailLoading = true;
	render();
	try {
		state.detail = await api.nexusMod(modId);
	} catch (error) {
		state.detail = null;
		toast(formatError(error), true);
	} finally {
		state.detailLoading = false;
		if (ui.tab === 'nexus') render();
	}
}

function buildNexusDetail(inner) {
	const state = ui.nexus;
	const mod = state.detail;
	if (state.detailLoading) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	const card = h('div', { class: 'card workshop-detail' },
		h('div', { class: 'hero-name' }, mod.name),
		h('div', { class: 'mod-meta' }, [`ID ${mod.modId}`, mod.author, mod.version && `v${mod.version}`, mod.category, mod.downloads ? t('nexus_downloads', { count: mod.downloads }) : ''].filter(Boolean).join(' · ')));
	if (mod.pictureUrl) {
		card.append(h('button', { class: 'workshop-shot', style: { backgroundImage: `url("${mod.pictureUrl.replace(/"/g, '%22')}")` }, onclick: () => showWorkshopImage(mod.pictureUrl) }));
	}
	card.append(h('div', { class: 'workshop-desc' }, mod.summary || t('mod_desc_none')),
		h('div', { class: 'actions' }, h('button', { class: 'btn ghost small', onclick: () => run(() => api.openExternal(mod.pageUrl)) }, icon('open_in_new'), t('workshop_open_web'))));
	card.append(h('h2', { class: 'section-heading' }, t('nexus_files')));
	if (!mod.files.length) {
		card.append(h('div', { class: 'muted' }, t('nexus_no_files')));
	}
	for (const file of mod.files) {
		card.append(h('div', { class: 'mod-card' }, h('div', { class: 'mod-head' }, icon(file.primary ? 'star' : 'description', 'muted'),
			h('div', { class: 'grow' }, h('div', { class: 'mod-name ellipsis' }, file.name),
				h('div', { class: 'mod-meta ellipsis' }, [file.category, file.version && `v${file.version}`, file.size ? formatBytes(file.size) : '', file.uploaded ? formatDate(file.uploaded) : ''].filter(Boolean).join(' · '))),
			h('button', { class: 'btn primary small', onclick: () => installNexusFile(mod, file) }, icon('download'), t('nexus_install')))));
	}
	inner.append(card);
}

async function installNexusFile(mod, file, nxm) {
	let plan;
	try {
		toast(t('workshop_preparing'));
		plan = await api.nexusPrepareInstall(mod.modId, file.fileId, nxm || '');
	} catch (error) {
		const message = error && error.message ? error.message : '';
		if (!nxm && /nexus_premium_required/.test(message)) {
			const link = await promptNxmLink(mod, file);
			if (link) await installNexusFile(mod, file, link);
			return;
		}
		toast(formatError(error), true);
		return;
	}
	if (await importPlanDialog(plan)) {
		await run(() => api.nexusCommitInstall(plan.token), ids => t('imported', { names: ids.join(', ') }));
	} else {
		api.nexusCancelInstall(plan.token).catch(error => logUi('W', '取消 Nexus 安装失败', error));
	}
}

function promptNxmLink(mod, file) {
	return modal((box, close) => {
		const input = h('input', { class: 'text-input mono', placeholder: 'nxm://slaythespire2/mods/…/files/…?key=…&expires=…', 'aria-label': t('nexus_nxm_title') });
		box.append(h('h2', {}, t('nexus_nxm_title')),
			h('div', { class: 'body' }, t('nexus_nxm_body')),
			input,
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(null) }, t('cancel')),
				h('button', { class: 'btn secondary small', onclick: () => api.openExternal(`https://www.nexusmods.com/slaythespire2/mods/${mod.modId}?tab=files&file_id=${file.fileId}`).catch(error => toast(formatError(error), true)) }, icon('open_in_new'), t('nexus_open_files')),
				h('button', { class: 'btn primary small', onclick: () => close(input.value.trim() || null) }, t('nexus_use_nxm'))));
	});
}

api.onNexusProgress(info => {
	if (info.total) toast(t('workshop_downloading', { percent: Math.round(info.received / info.total * 100) }));
});

registerPage('nexus', { build: buildNexusPage, parent: 'mods', onOpen: () => { ui.nexus.config = null; ui.nexus.detail = null; } });
