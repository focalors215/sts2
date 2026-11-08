'use strict';

/* 日志 AI 分析（对齐 Android LogAnalysisActivity）：用户自配 OpenAI 兼容服务；只勾选的 1–3 个日志
 * 可被模型通过只读工具按需读取，不自动上传全文；首次发送前征求同意；对话只在内存里。 */
ui.ai = {
	config: null,
	picked: new Set(),
	session: null,
	consented: false,
	transcript: [],
	busy: false,
	draft: '',
};

function openLogAnalysis() {
	if (!ui.ai.session && ui.logs.selected) {
		ui.ai.picked = new Set([ui.logs.selected]);
	}
	openTab('analysis');
}

async function loadAiConfig() {
	try {
		ui.ai.config = await api.aiGetConfig();
	} catch (error) {
		toast(formatError(error), true);
		ui.ai.config = { baseUrl: '', model: '', reasoningEffort: '', hasKey: false };
	}
	if (!ui.logs.sources) {
		try {
			ui.logs.sources = await api.listLogs();
		} catch (error) {
			toast(formatError(error), true);
			ui.logs.sources = [];
		}
	}
	if (ui.tab === 'analysis') render();
}

function buildAnalysisPage(inner) {
	const state = ui.ai;
	if (!state.config) {
		loadAiConfig();
	}
	inner.append(h('div', { class: 'page-header' },
		h('div', { class: 'row' }, h('button', { class: 'icon-btn', title: t('back'), 'aria-label': t('back'), onclick: () => openTab('logs') }, icon('arrow_back')),
			pageTitle(t('ai_title'), t('ai_tagline')))));
	inner.append(h('div', { class: 'card compact notice' }, icon('privacy_tip'), h('span', {}, t('ai_privacy'))));
	if (!state.config) {
		inner.append(h('div', { class: 'empty' }, t('ai_loading')));
		return;
	}
	inner.append(aiConfigCard(), aiFilesCard(), aiChatCard());
}

function aiConfigCard() {
	const config = ui.ai.config;
	const field = (label, value, attrs) => {
		const input = h('input', { class: 'text-input', value, spellcheck: false, autocomplete: 'off', 'aria-label': label, ...attrs });
		return [h('div', { class: 'setting-title' }, label), input];
	};
	const [baseLabel, base] = field(t('ai_base_url'), config.baseUrl, { placeholder: 'https://api.example.com/v1' });
	const [keyLabel, key] = field(t('ai_api_key'), '', { type: 'password', placeholder: config.hasKey ? t('ai_key_saved') : t('ai_key_empty') });
	const [modelLabel, model] = field(t('ai_model'), config.model, {});
	const [effortLabel, effort] = field(t('ai_effort'), config.reasoningEffort, { placeholder: 'low / medium / high' });
	const save = clearKey => run(async () => {
		const patch = { baseUrl: base.value, model: model.value, reasoningEffort: effort.value };
		if (clearKey) {
			patch.apiKey = '';
		} else if (key.value.trim()) {
			patch.apiKey = key.value;
		}
		await api.aiSaveConfig(patch);
		resetAiTranscript();
		ui.ai.config = await api.aiGetConfig();
	}, clearKey ? t('ai_key_cleared') : t('ai_saved'));
	const details = h('details', { class: 'card compact', open: !config.baseUrl || !config.model },
		h('summary', { class: 'setting-title' }, icon('tune'), ' ', t('ai_config'), config.model ? h('span', { class: 'muted' }, `  ·  ${config.model}`) : null),
		h('div', { class: 'setting-desc' }, t('ai_config_notice')),
		baseLabel, base, keyLabel, key, modelLabel, model, effortLabel, effort,
		h('div', { class: 'actions' },
			config.hasKey ? h('button', { class: 'btn ghost small', onclick: () => save(true) }, t('ai_clear_key')) : null,
			h('button', { class: 'btn primary small', onclick: () => save(false) }, icon('lock'), t('ai_save'))));
	return details;
}

function aiFilesCard() {
	const state = ui.ai;
	const sources = ui.logs.sources || [];
	const card = h('div', { class: 'card compact' }, h('div', { class: 'setting-title' }, icon('checklist'), ' ', t('ai_files')),
		h('div', { class: 'setting-desc' }, t('ai_select_notice')));
	const list = h('div', { class: 'ai-files' });
	for (const source of sources.slice(0, 30)) {
		const input = h('input', { type: 'checkbox', 'aria-label': source.name });
		input.checked = state.picked.has(source.id);
		input.addEventListener('change', () => {
			if (input.checked && state.picked.size >= 3) {
				input.checked = false;
				toast(t('ai_max_files'), true);
				return;
			}
			if (input.checked) state.picked.add(source.id); else state.picked.delete(source.id);
		});
		list.append(h('label', { class: 'ai-file' }, input, h('span', { class: 'grow ellipsis' }, source.name),
			h('span', { class: 'muted' }, `${t(`logs_kind_${source.kind}`)} · ${formatBytes(source.size)}`)));
	}
	card.append(list, h('div', { class: 'actions' },
		h('button', { class: 'btn secondary small', onclick: startAiSession }, icon('done_all'), state.session ? t('ai_confirm_restart') : t('ai_confirm'))));
	if (state.session) {
		card.append(h('div', { class: 'setting-desc' }, t('ai_session_files', { names: state.session.files.map(f => `${f.file_id} = ${f.name}`).join('，') })));
	}
	return card;
}

async function startAiSession() {
	const state = ui.ai;
	if (!state.picked.size) {
		toast(t('ai_no_files'), true);
		return;
	}
	try {
		state.session = await api.aiStart([...state.picked]);
		state.consented = false;
		state.transcript = [];
		toast(t('ai_ready'));
	} catch (error) {
		state.session = null;
		toast(formatError(error), true);
	}
	render();
}

function resetAiTranscript() {
	ui.ai.session = null;
	ui.ai.consented = false;
	ui.ai.transcript = [];
}

function aiChatCard() {
	const state = ui.ai;
	const card = h('div', { class: 'card compact ai-chat' });
	const log = h('div', { class: 'ai-transcript' });
	if (!state.transcript.length) {
		log.append(h('div', { class: 'muted' }, t('ai_welcome')));
	}
	for (const entry of state.transcript) {
		log.append(h('div', { class: `ai-msg ${entry.role}` },
			h('div', { class: 'ai-role' }, t(`ai_role_${entry.role}`)),
			h('div', { class: 'ai-text' }, entry.text)));
	}
	const question = h('textarea', { class: 'text-input', rows: '3', placeholder: t('ai_question'), 'aria-label': t('ai_question') });
	question.value = state.draft;
	question.addEventListener('input', () => { state.draft = question.value; });
	question.addEventListener('keydown', event => {
		if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) sendAiQuestion();
	});
	const status = state.busy ? t('ai_working') : state.session ? t('ai_ready_status') : t('ai_no_session');
	card.append(h('div', { class: 'row' }, h('div', { class: 'setting-title grow' }, icon('forum'), ' ', t('ai_chat')), h('span', { class: 'muted' }, status)),
		log, question,
		h('div', { class: 'actions' },
			state.session ? h('button', { class: 'btn ghost small', disabled: state.busy, onclick: () => { resetAiTranscript(); render(); } }, t('ai_restart')) : null,
			state.busy ? h('button', { class: 'btn danger small', onclick: () => api.aiStop().catch(error => toast(formatError(error), true)) }, icon('stop'), t('ai_stop')) : null,
			h('button', { class: 'btn primary small', disabled: state.busy || !state.session, onclick: sendAiQuestion }, icon('send'), t('ai_send'))));
	requestAnimationFrame(() => { log.scrollTop = log.scrollHeight; });
	return card;
}

async function sendAiQuestion() {
	const state = ui.ai;
	const text = state.draft.trim();
	if (!text || state.busy || !state.session) {
		return;
	}
	if (!state.consented) {
		const ok = await confirmDialog(t('ai_consent_title'), t('ai_consent', {
			endpoint: state.session.endpoint,
			files: state.session.files.map(f => f.name).join('\n'),
		}), t('ai_agree'));
		if (!ok) return;
		state.consented = true;
	}
	state.busy = true;
	state.draft = '';
	state.transcript.push({ role: 'user', text });
	render();
	try {
		const result = await api.aiAsk(text);
		state.transcript.push({ role: 'assistant', text: result.text });
		if (result.budgetReached) toast(t('ai_budget'));
	} catch (error) {
		state.transcript.push({ role: 'error', text: formatError(error) });
	} finally {
		state.busy = false;
		if (ui.tab === 'analysis') render();
	}
}

api.onAiProgress(summary => {
	ui.ai.transcript.push({ role: 'tool', text: summary });
	if (ui.tab === 'analysis') render();
});

registerPage('analysis', { build: buildAnalysisPage, parent: 'logs' });
