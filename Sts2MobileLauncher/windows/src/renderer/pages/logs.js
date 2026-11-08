'use strict';

/* 日志页（规范 §5.5，对齐 Android LogViewerActivity / LogFileViewerActivity）：
 * 左侧按来源列出启动器 / 游戏 / 联机 / frp 日志与崩溃报告，右侧查看尾部、搜索、按级别过滤；
 * 顶部「导出日志」打包 zip（含 diagnostics.json），「AI 分析」见 pages/analysis.js。 */
ui.logs = {
	sources: null,
	loading: false,
	kind: 'all',
	selected: '',
	content: null,
	contentLoading: false,
	query: '',
	levels: new Set(['D', 'I', 'W', 'E']),
};

const LOG_KINDS = ['all', 'launcher', 'game', 'online', 'frp', 'crash'];
const MAX_RENDERED_LINES = 5000;

function formatBytes(size) {
	if (size < 1024) return `${size} B`;
	if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
	return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

async function loadLogSources(selectFirst) {
	ui.logs.loading = true;
	try {
		ui.logs.sources = await api.listLogs();
		if (selectFirst || !ui.logs.sources.some(source => source.id === ui.logs.selected)) {
			const first = ui.logs.sources.find(source => ui.logs.kind === 'all' || source.kind === ui.logs.kind);
			if (first) {
				await openLog(first.id, false);
			} else {
				ui.logs.selected = '';
				ui.logs.content = null;
			}
		}
	} catch (error) {
		toast(formatError(error), true);
		ui.logs.sources = ui.logs.sources || [];
	} finally {
		ui.logs.loading = false;
		if (ui.tab === 'logs') render();
	}
}

async function openLog(id, rerender = true) {
	ui.logs.selected = id;
	ui.logs.contentLoading = true;
	if (rerender) render();
	try {
		ui.logs.content = await api.readLog(id);
	} catch (error) {
		ui.logs.content = null;
		toast(formatError(error), true);
	} finally {
		ui.logs.contentLoading = false;
		if (rerender && ui.tab === 'logs') render();
	}
}

async function exportLogs() {
	try {
		const result = await api.exportLogs();
		if (result) {
			toast(t('logs_exported', { file: result.file }));
		}
	} catch (error) {
		toast(formatError(error), true);
	}
}

function buildLogsPage(inner, wide) {
	const state = ui.logs;
	if (!state.sources && !state.loading) {
		loadLogSources(true);
	}
	inner.append(h('div', { class: 'page-header' }, pageTitle(t('nav_logs'), t('tagline_logs')),
		h('div', { class: 'chip-row' },
			h('button', { class: 'btn primary small', onclick: exportLogs }, icon('ios_share'), t('logs_export')),
			typeof openLogAnalysis === 'function' ? h('button', { class: 'btn secondary small', onclick: () => openLogAnalysis() }, icon('auto_awesome'), t('logs_ai')) : null)));
	inner.append(h('div', { class: 'card compact notice' }, icon('info'), h('span', {}, t('logs_hint'))));
	const sources = state.sources || [];
	const counts = Object.fromEntries(LOG_KINDS.map(kind => [kind, kind === 'all' ? sources.length : sources.filter(s => s.kind === kind).length]));
	inner.append(h('div', { class: 'chip-row' },
		LOG_KINDS.map(kind => h('button', { class: `chip${state.kind === kind ? ' selected' : ''}`, onclick: () => { state.kind = kind; render(); } },
			`${t(`logs_kind_${kind}`)} ${counts[kind]}`)),
		h('button', { class: 'chip', onclick: () => loadLogSources(false) }, icon('refresh'), t('refresh')),
		h('button', { class: 'chip', onclick: () => run(() => api.open('launcherLogs')) }, icon('folder_open'), t('logs_open_launcher_dir')),
		h('button', { class: 'chip', onclick: () => run(() => api.open('logs')) }, icon('folder_open'), t('logs_open_game_dir'))));

	const list = h('div', { class: 'log-files' });
	const visible = sources.filter(source => state.kind === 'all' || source.kind === state.kind);
	if (!state.sources) {
		list.append(h('div', { class: 'empty' }, t('logs_loading')));
	} else if (!visible.length) {
		list.append(h('div', { class: 'empty' }, t('logs_empty')));
	}
	for (const source of visible) {
		list.append(h('button', { class: `log-file${source.id === state.selected ? ' selected' : ''}`, onclick: () => openLog(source.id) },
			icon({ launcher: 'rocket_launch', game: 'stadia_controller', online: 'groups', frp: 'cell_tower', crash: 'bug_report' }[source.kind] || 'description', 'muted'),
			h('div', { class: 'grow' },
				h('div', { class: 'log-file-name ellipsis' }, source.name),
				h('div', { class: 'log-file-meta' }, `${t(`logs_kind_${source.kind}`)} · ${formatBytes(source.size)} · ${new Date(source.mtimeMs).toLocaleString()}`))));
	}

	const viewer = h('div', { class: 'log-viewer card compact' });
	buildLogViewer(viewer);
	inner.append(h('div', { class: `logs-layout${wide ? ' wide' : ''}` }, list, viewer));
}

function buildLogViewer(viewer) {
	const state = ui.logs;
	const search = h('input', { type: 'search', placeholder: t('logs_search'), value: state.query, 'aria-label': t('logs_search') });
	const lines = h('div', { class: 'log-lines mono', role: 'log' });
	const meta = h('span', { class: 'log-meta muted' });
	search.addEventListener('input', () => {
		state.query = search.value;
		renderLogLines(lines, meta);
	});
	const levelChips = ['E', 'W', 'I', 'D'].map(level => {
		const chip = h('button', { class: `chip level lvl-${level}${state.levels.has(level) ? ' selected' : ''}`, title: t(`logs_level_${level}`), 'aria-pressed': state.levels.has(level) ? 'true' : 'false' }, level);
		chip.addEventListener('click', () => {
			if (state.levels.has(level)) state.levels.delete(level); else state.levels.add(level);
			chip.classList.toggle('selected', state.levels.has(level));
			chip.setAttribute('aria-pressed', state.levels.has(level) ? 'true' : 'false');
			renderLogLines(lines, meta);
		});
		return chip;
	});
	viewer.append(h('div', { class: 'row wrap' }, h('label', { class: 'search grow' }, icon('search'), search), ...levelChips,
		h('button', { class: 'icon-btn', title: t('logs_copy'), 'aria-label': t('logs_copy'), onclick: () => copyVisibleLines() }, icon('content_copy')),
		h('button', { class: 'icon-btn', title: t('logs_bottom'), 'aria-label': t('logs_bottom'), onclick: () => { lines.scrollTop = lines.scrollHeight; } }, icon('vertical_align_bottom'))));
	viewer.append(meta, lines);
	if (state.contentLoading) {
		lines.append(h('div', { class: 'muted' }, t('logs_reading')));
		return;
	}
	if (!state.content) {
		lines.append(h('div', { class: 'muted' }, t('logs_pick')));
		return;
	}
	renderLogLines(lines, meta);
	requestAnimationFrame(() => { lines.scrollTop = lines.scrollHeight; });
}

function filteredRows() {
	const state = ui.logs;
	if (!state.content) return [];
	const query = state.query.trim().toLowerCase();
	return state.content.rows.filter(row => state.levels.has(row.level) && (!query || row.text.toLowerCase().includes(query)));
}

function renderLogLines(container, meta) {
	const state = ui.logs;
	const rows = filteredRows();
	const shown = rows.slice(-MAX_RENDERED_LINES);
	const query = state.query.trim();
	const fragment = document.createDocumentFragment();
	for (const row of shown) {
		const line = document.createElement('div');
		line.className = `log-line lvl-${row.level}`;
		if (query) {
			highlight(line, row.text, query);
		} else {
			line.textContent = row.text || ' ';
		}
		fragment.append(line);
	}
	container.replaceChildren(fragment);
	if (!rows.length) {
		container.append(h('div', { class: 'muted' }, t('logs_no_match')));
	}
	const total = state.content ? state.content.rows.length : 0;
	let text = t('logs_line_count', { shown: rows.length, total });
	if (rows.length > shown.length) text += t('logs_only_last', { count: MAX_RENDERED_LINES });
	if (state.content && state.content.truncated) text += t('logs_truncated', { size: formatBytes(state.content.size) });
	meta.textContent = text;
}

function highlight(line, text, query) {
	const lower = text.toLowerCase();
	const needle = query.toLowerCase();
	let index = 0;
	let found;
	while ((found = lower.indexOf(needle, index)) >= 0) {
		line.append(text.slice(index, found), h('mark', {}, text.slice(found, found + needle.length)));
		index = found + needle.length;
	}
	line.append(text.slice(index));
}

async function copyVisibleLines() {
	try {
		await navigator.clipboard.writeText(filteredRows().map(row => row.text).join('\n'));
		toast(t('logs_copied'));
	} catch (error) {
		logUi('W', '复制日志失败', error);
		toast(formatError(error), true);
	}
}

registerPage('logs', { build: buildLogsPage, onOpen: () => { ui.logs.sources = null; } });
