'use strict';

/* 云存档（对齐 Android WebDavCloudActivity 与设置页的云存档模式）：WebDAV 连接、模式、手动拉取 / 上传 /
 * 强制上传、冲突时选择保留哪份；启动前拉取由 cloudBeforeLaunch() 在每次启动游戏前执行。 */
ui.cloud = { config: null, busy: false, progress: '' };

const CLOUD_MODES = ['off', 'manual', 'pull_on_launch', 'full_auto'];

async function loadCloudConfig() {
	try {
		ui.cloud.config = await api.cloudGetConfig();
	} catch (error) {
		toast(formatError(error), true);
		ui.cloud.config = { url: '', username: '', slot: '', mode: 'manual', includeSettingsSave: false, hasPassword: false };
	}
	if (ui.tab === 'cloud') render();
}

function buildCloudPage(inner) {
	const state = ui.cloud;
	if (!state.config) loadCloudConfig();
	inner.append(h('div', { class: 'page-header' },
		h('div', { class: 'row' }, h('button', { class: 'icon-btn', title: t('back'), 'aria-label': t('back'), onclick: () => { ui.settingsSegment = 'saves'; openTab('settings'); } }, icon('arrow_back')),
			pageTitle(t('cloud_title'), t('cloud_tagline')))));
	if (!state.config) {
		inner.append(h('div', { class: 'empty' }, t('workshop_loading')));
		return;
	}
	const cfg = state.config;
	const field = (label, value, attrs) => [h('div', { class: 'setting-title' }, label), h('input', { class: 'text-input', value, spellcheck: false, autocomplete: 'off', 'aria-label': label, ...attrs })];
	const [urlLabel, url] = field(t('webdav_url'), cfg.url, { placeholder: 'https://example.com/dav/STS2/' });
	const [userLabel, user] = field(t('webdav_username'), cfg.username, {});
	const [passLabel, pass] = field(t('webdav_password'), '', { type: 'password', placeholder: cfg.hasPassword ? t('ai_key_saved') : t('ai_key_empty') });
	const [slotLabel, slot] = field(t('webdav_slot'), cfg.slot, { placeholder: t('webdav_slot_placeholder') });
	const saveConnection = () => run(async () => {
		const patch = { url: url.value, username: user.value, slot: slot.value };
		if (pass.value) patch.password = pass.value;
		await api.cloudSaveConfig(patch);
		ui.cloud.config = null;
	}, t('webdav_saved'));
	inner.append(h('div', { class: 'card compact column-gap' },
		h('div', { class: 'setting-title' }, icon('cloud'), ' ', t('webdav_connection')),
		h('div', { class: 'setting-desc' }, t('webdav_connection_desc')),
		urlLabel, url, userLabel, user, passLabel, pass, slotLabel, slot,
		h('div', { class: 'actions' },
			cfg.url ? h('button', { class: 'btn ghost small', onclick: clearCloud }, t('webdav_clear')) : null,
			cfg.url ? h('button', { class: 'btn secondary small', disabled: state.busy, onclick: () => cloudOperation('test') }, icon('network_check'), t('webdav_test')) : null,
			h('button', { class: 'btn primary small', onclick: saveConnection }, icon('lock'), t('save')))));

	const modeRow = h('button', { class: 'setting clickable', onclick: async () => {
		const value = await choiceDialog(t('webdav_mode'), CLOUD_MODES.map(mode => ({ value: mode, label: t(`webdav_mode_${mode}`) })), cfg.mode);
		if (value !== undefined && value !== cfg.mode) {
			await run(() => api.cloudSaveConfig({ mode: value }));
			ui.cloud.config = null;
			render();
		}
	} }, icon('sync', 'lead'), h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('webdav_mode')), h('div', { class: 'setting-desc' }, t('webdav_mode_desc'))),
	h('span', { class: 'setting-value' }, t(`webdav_mode_${cfg.mode}`)), icon('chevron_right', 'muted'));
	const settingsToggle = h('div', { class: 'setting' }, icon('tune', 'lead'),
		h('div', { class: 'grow' }, h('div', { class: 'setting-title' }, t('webdav_sync_settings')), h('div', { class: 'setting-desc' }, t('webdav_sync_settings_desc'))),
		switchControl(cfg.includeSettingsSave, value => run(async () => { await api.cloudSaveConfig({ includeSettingsSave: value }); ui.cloud.config = null; }), !cfg.url, t('webdav_sync_settings')));
	inner.append(h('div', { class: 'settings-grid' }, modeRow, settingsToggle));

	const status = cfg.status;
	inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', { class: 'pre-line' }, [
		t('webdav_status', { slot: status ? status.slot : '-', remote: status ? status.remoteDir : '-', files: status ? status.remoteFiles : 0 }),
		cfg.lastPull ? `\n${t('webdav_last_pull', { time: new Date(cfg.lastPull).toLocaleString() })}` : '',
		cfg.lastPush ? `\n${t('webdav_last_push', { time: new Date(cfg.lastPush).toLocaleString() })}` : '',
		cfg.lastError ? `\n${t('webdav_last_error', { error: cfg.lastError })}` : '',
	].join(''))));
	if (state.busy) {
		inner.append(h('div', { class: 'card compact notice' }, icon('sync'), h('span', {}, state.progress || t('webdav_busy'))));
	}
	inner.append(h('div', { class: 'chip-row' },
		h('button', { class: 'btn secondary small', disabled: !cfg.url || state.busy, onclick: () => cloudOperation('refresh') }, icon('refresh'), t('webdav_refresh')),
		h('button', { class: 'btn secondary small', disabled: !cfg.url || state.busy, onclick: async () => {
			if (await confirmDialog(t('webdav_pull_confirm_title'), t('webdav_pull_confirm'), t('webdav_pull'))) cloudOperation('pull');
		} }, icon('cloud_download'), t('webdav_pull')),
		h('button', { class: 'btn primary small', disabled: !cfg.url || state.busy, onclick: () => cloudOperation('push') }, icon('cloud_upload'), t('webdav_push')),
		h('button', { class: 'btn danger small', disabled: !cfg.url || state.busy, onclick: async () => {
			if (await confirmDialog(t('webdav_force_push_title'), t('webdav_force_push_confirm'), t('webdav_force_push'), true)) cloudOperation('push', true);
		} }, icon('upload'), t('webdav_force_push'))));

	inner.append(h('h2', { class: 'section-heading' }, t('steam_cloud_title')),
		h('div', { class: 'card compact notice warn' }, icon('cloud_off'), h('span', {}, t('steam_cloud_windows'))));
}

async function clearCloud() {
	if (await confirmDialog(t('webdav_clear_title'), t('webdav_clear_body'), t('webdav_clear'), true)) {
		await run(() => api.cloudClear(), t('webdav_cleared'));
		ui.cloud.config = null;
		render();
	}
}

/** 执行一次云操作；冲突时让用户选择保留哪份。返回是否成功（冲突后选择取消也算失败）。 */
async function cloudOperation(kind, force) {
	const state = ui.cloud;
	state.busy = true;
	state.progress = '';
	render();
	let result;
	try {
		result = await (kind === 'test' ? api.cloudTest() : kind === 'refresh' ? api.cloudRefresh() : kind === 'pull' ? api.cloudPull(!!force) : api.cloudPush(!!force));
	} catch (error) {
		toast(formatError(error), true);
		return false;
	} finally {
		state.busy = false;
		state.config = null;
		render();
	}
	if (result.ok) {
		toast(cloudSummary(kind, result));
		return true;
	}
	return resolveCloudConflict(result.conflicts);
}

function cloudSummary(kind, result) {
	if (kind === 'test') return t('webdav_test_ok', { dir: result.remoteDir });
	if (kind === 'refresh') return t('webdav_refreshed', { count: result.remoteFiles });
	if (kind === 'pull') return result.downloaded ? t('webdav_pulled', { count: result.downloaded, preserved: result.preserved, backup: result.backup }) : t('webdav_pull_none');
	return result.uploaded ? t('webdav_pushed', { count: result.uploaded }) : t('webdav_push_none');
}

async function resolveCloudConflict(conflicts) {
	const choice = await modal((box, close) => {
		box.append(h('h2', {}, t('webdav_conflict_title')),
			h('div', { class: 'body' }, t('webdav_conflict', { count: conflicts.length, files: conflicts.slice(0, 8).join('\n') })),
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost small', onclick: () => close(null) }, t('cancel')),
				h('button', { class: 'btn secondary small', onclick: () => close('cloud') }, t('webdav_keep_cloud')),
				h('button', { class: 'btn primary small', onclick: () => close('local') }, t('webdav_keep_local'))));
	});
	if (!choice) {
		return false;
	}
	return cloudOperation(choice === 'cloud' ? 'pull' : 'push', true);
}

/**
 * 启动游戏前（模式为「启动前拉取」或「完整自动」时）先从 WebDAV 拉取，同 Android：
 * 冲突让用户选；失败时询问是否仍然启动。返回 false 表示取消这次启动。
 */
async function cloudBeforeLaunch() {
	let cfg;
	try {
		cfg = await api.cloudGetConfig();
	} catch (error) {
		logUi('W', '读取云存档配置失败，跳过启动前拉取', error);
		return true;
	}
	if (!cfg.url || (cfg.mode !== 'pull_on_launch' && cfg.mode !== 'full_auto')) {
		return true;
	}
	toast(t('webdav_auto_pull'));
	let result;
	try {
		result = await api.cloudPull(false);
	} catch (error) {
		return confirmDialog(t('webdav_launch_failed_title'), t('webdav_launch_failed', { error: formatError(error) }), t('webdav_launch_anyway'));
	}
	if (result.ok) {
		if (result.downloaded) toast(cloudSummary('pull', result));
		return true;
	}
	return resolveCloudConflict(result.conflicts);
}

api.onCloudProgress(info => {
	ui.cloud.progress = `${info.percent}% · ${info.message}`;
	if (ui.tab === 'cloud' && ui.cloud.busy) render();
});

api.onCloudAuto(info => {
	if (info.error) {
		toast(t('webdav_auto_push_failed', { error: info.error }), true);
	} else if (info.result && info.result.ok === false) {
		toast(t('webdav_auto_push_conflict'), true);
	} else if (info.result && info.result.uploaded) {
		toast(t('webdav_pushed', { count: info.result.uploaded }));
	}
});

registerPage('cloud', { build: buildCloudPage, parent: 'settings', onOpen: () => { ui.cloud.config = null; } });
