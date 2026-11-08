'use strict';

/* 文件浏览 / 文本编辑（对齐 Android FileBrowserActivity / TextEditorActivity）、整机数据备份、启动器更新检查。 */
ui.files = { roots: null, root: 'saves', path: '', listing: null, loading: false };
ui.backup = { measure: null, includeMods: false };

async function loadFiles() {
	const state = ui.files;
	state.loading = true;
	try {
		state.roots = state.roots || await api.filesRoots();
		if (!state.roots.some(root => root.id === state.root)) state.root = state.roots[0].id;
		state.listing = await api.filesList(state.root, state.path);
	} catch (error) {
		toast(formatError(error), true);
		state.listing = { relative: state.path, entries: [] };
	} finally {
		state.loading = false;
		if (ui.tab === 'files') render();
	}
}

function openFilesDir(relative) {
	ui.files.path = relative;
	ui.files.listing = null;
	loadFiles();
	render();
}

function buildFilesPage(inner) {
	const state = ui.files;
	if (!state.listing && !state.loading) loadFiles();
	inner.append(h('div', { class: 'page-header' },
		h('div', { class: 'row' }, h('button', { class: 'icon-btn', title: t('back'), 'aria-label': t('back'), onclick: () => openTab('settings') }, icon('arrow_back')),
			pageTitle(t('files_title'), t('files_tagline')))));
	inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', {}, t('files_hint'))));
	if (state.roots) {
		inner.append(h('div', { class: 'chip-row' }, state.roots.map(root => h('button', { class: `chip${state.root === root.id ? ' selected' : ''}`, title: root.path, onclick: () => { state.root = root.id; openFilesDir(''); } }, t(root.label)))));
	}
	const parts = state.path ? state.path.split('/') : [];
	const crumbs = h('div', { class: 'chip-row crumbs' }, h('button', { class: 'link', onclick: () => openFilesDir('') }, state.roots ? t((state.roots.find(r => r.id === state.root) || {}).label || '') : '/'));
	parts.forEach((part, index) => crumbs.append(h('span', { class: 'muted' }, '/'), h('button', { class: 'link', onclick: () => openFilesDir(parts.slice(0, index + 1).join('/')) }, part)));
	inner.append(h('div', { class: 'row wrap' }, h('div', { class: 'grow' }, crumbs),
		h('button', { class: 'chip', onclick: () => run(() => api.filesReveal(state.root, state.path)) }, icon('folder_open'), t('files_reveal')),
		h('button', { class: 'chip', onclick: () => openFilesDir(state.path) }, icon('refresh'), t('refresh'))));
	const list = h('div', { class: 'log-files files-list' });
	if (!state.listing) {
		list.append(h('div', { class: 'empty' }, t('workshop_loading')));
	} else if (state.listing.missing) {
		list.append(h('div', { class: 'empty' }, t('files_missing')));
	} else if (!state.listing.entries.length) {
		list.append(h('div', { class: 'empty' }, t('files_empty')));
	} else {
		if (parts.length) {
			list.append(h('button', { class: 'log-file', onclick: () => openFilesDir(parts.slice(0, -1).join('/')) }, icon('arrow_upward', 'muted'), h('div', { class: 'grow' }, '..')));
		}
		for (const entry of state.listing.entries) {
			const relative = state.path ? `${state.path}/${entry.name}` : entry.name;
			list.append(h('button', { class: 'log-file', onclick: () => (entry.dir ? openFilesDir(relative) : entry.text ? editTextFile(relative) : run(() => api.filesReveal(state.root, relative))) },
				icon(entry.dir ? 'folder' : entry.text ? 'description' : 'draft', 'muted'),
				h('div', { class: 'grow' }, h('div', { class: 'log-file-name ellipsis' }, entry.name),
					h('div', { class: 'log-file-meta' }, entry.dir ? t('files_folder') : `${formatBytes(entry.size)} · ${new Date(entry.mtimeMs).toLocaleString()}`)),
				!entry.dir && entry.text ? icon('edit', 'muted') : null));
		}
	}
	inner.append(list);
}

async function editTextFile(relative) {
	const state = ui.files;
	let content;
	try {
		content = await api.filesRead(state.root, relative);
	} catch (error) {
		toast(formatError(error), true);
		return;
	}
	let mtimeMs = content.mtimeMs;
	await modal((box, close) => {
		box.classList.add('editor-modal');
		const area = h('textarea', { class: 'text-input mono editor-area', spellcheck: false, 'aria-label': relative });
		area.value = content.text;
		const save = async () => {
			try {
				const result = await api.filesWrite(state.root, relative, area.value, mtimeMs);
				mtimeMs = result.mtimeMs;
				toast(t('files_saved'));
				close(true);
			} catch (error) {
				toast(formatError(error), true);
			}
		};
		area.addEventListener('keydown', event => {
			if (event.key === 's' && (event.ctrlKey || event.metaKey)) {
				event.preventDefault();
				save();
			}
		});
		box.append(h('h2', { class: 'ellipsis' }, relative.split('/').pop()),
			h('div', { class: 'setting-desc' }, t('files_editor_hint')),
			area,
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(false) }, t('cancel')),
				h('button', { class: 'btn primary small', onclick: save }, icon('save'), t('save'))));
	});
	openFilesDir(state.path);
}

/** 设置 → 存档：整机数据备份卡片。 */
function backupCard() {
	const state = ui.backup;
	if (!state.measure) {
		api.backupMeasure().then(measure => {
			state.measure = measure;
			if (ui.tab === 'settings') render();
		}).catch(error => logUi('W', '统计备份大小失败', error));
	}
	const m = state.measure;
	return h('div', { class: 'card compact column-gap' },
		h('div', { class: 'setting-title' }, icon('backup'), ' ', t('backup_title')),
		h('div', { class: 'setting-desc' }, t('backup_info')),
		h('div', { class: 'muted' }, m ? t('backup_size', { saves: formatBytes(m.saveBytes), saveFiles: m.saveFiles, mods: formatBytes(m.modBytes), modFiles: m.modFiles }) : t('backup_measuring')),
		h('div', { class: 'row' }, h('div', { class: 'grow setting-desc' }, t('backup_include_mods')), switchControl(state.includeMods, value => { state.includeMods = value; }, false, t('backup_include_mods'))),
		h('div', { class: 'actions' },
			h('button', { class: 'btn secondary small', onclick: importBackup }, icon('settings_backup_restore'), t('backup_import')),
			h('button', { class: 'btn primary small', onclick: () => run(() => api.backupExport(state.includeMods), result => (result ? t('backup_exported', { file: result.file }) : '')) }, icon('ios_share'), t('backup_export'))));
}

async function importBackup() {
	if (!await confirmDialog(t('backup_import_title'), t('backup_import_confirm'), t('backup_import'), true)) {
		return;
	}
	await run(() => api.backupImport(), result => (result ? t('backup_imported', { saves: result.savesRestored, mods: result.modsRestored, safety: result.safety }) : ''));
	ui.backup.measure = null;
}

/** 关于页：检查更新。 */
function updateCard() {
	const settings = ui.state.updateSettings || {};
	return h('div', { class: 'card compact column-gap' },
		h('div', { class: 'row' }, icon('system_update', 'lead'), h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('update_title')), h('div', { class: 'setting-desc' }, t('update_desc'))),
			h('button', { class: 'btn secondary small', onclick: manualUpdateCheck }, icon('refresh'), t('update_check'))),
		h('div', { class: 'row' }, h('div', { class: 'grow setting-desc' }, t('update_auto')),
			switchControl(settings.autoCheck !== false, value => run(() => api.updateSettings2({ autoCheck: value })), false, t('update_auto'))));
}

async function manualUpdateCheck() {
	try {
		toast(t('update_checking'));
		const result = await api.checkUpdate();
		if (result.status === 'update') {
			showUpdateDialog(result);
		} else if (result.status === 'latest') {
			toast(t('update_latest', { version: ui.state.appVersion }));
		} else {
			toast(t('update_unavailable'));
		}
	} catch (error) {
		toast(formatError(error), true);
	}
}

async function showUpdateDialog(info) {
	const open = await modal((box, close) => {
		box.append(h('h2', {}, t('update_found', { version: info.version })),
			h('div', { class: 'body' }, t('update_found_body', { current: ui.state.appVersion, version: info.version }) + (info.prerelease ? t('update_prerelease') : '')),
			info.notes ? h('div', { class: 'workshop-desc' }, info.notes.slice(0, 4000)) : null,
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(false) }, t('update_later')),
				h('button', { class: 'btn primary small', onclick: () => close(true) }, icon('open_in_new'), t('update_open'))));
	});
	if (open) {
		run(() => api.openExternal(info.url || info.releasesUrl));
	}
}

api.onUpdateAvailable(info => showUpdateDialog(info));

registerPage('files', { build: buildFilesPage, parent: 'settings', onOpen: () => { ui.files.listing = null; ui.files.roots = null; } });
