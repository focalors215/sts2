'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULT_SETTINGS = Object.freeze({
	windowMode: 'default',      // default / fullscreen / windowed
	renderer: 'default',        // default / vulkan / d3d12 / opengl3
	logLevel: 'info',           // off / info / debug / very_debug（与 Android log_level 同义）
	afterLaunch: 'minimize',    // keep / minimize / close
	language: 'auto',           // auto / zh / en
	extraArgs: '',
	saveRoot: '',               // 空 = 自动（%APPDATA%\SlayTheSpire2）
	saveAccount: '',            // 相对 saveRoot 的账号目录，空 = 最近修改的那个
	snapshotBeforeLaunch: true,
	snapshotKeep: 5,
});

/** 启动器自己的配置：启动配置列表（游戏目录）与全局设置，保存在 userData/launcher.json。 */
class LauncherConfig {
	constructor(directory) {
		this.directory = directory;
		this.file = path.join(directory, 'launcher.json');
		this.data = this.load();
	}

	load() {
		let raw = {};
		try {
			raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
		} catch (error) {
			raw = {};
		}
		const profiles = Array.isArray(raw.profiles) ? raw.profiles.filter(p => p && typeof p.gameDir === 'string') : [];
		const legacyProfiles = raw.version === undefined || raw.version === 1;
		return {
			version: 2,
			profiles: profiles.map(p => normalizeProfile(legacyProfiles && p.source === 'steam' ? { ...p, launchViaSteam: false } : p)),
			selectedProfileId: typeof raw.selectedProfileId === 'string' ? raw.selectedProfileId : '',
			lastTab: typeof raw.lastTab === 'string' ? raw.lastTab : 'home',
			settings: normalizeSettings(raw.settings),
			welcomeDone: raw.welcomeDone === true,
		};
	}

	save() {
		fs.mkdirSync(this.directory, { recursive: true });
		const temp = `${this.file}.${process.pid}.tmp`;
		fs.writeFileSync(temp, JSON.stringify(this.data, null, 2), 'utf8');
		fs.renameSync(temp, this.file);
	}

	get settings() {
		return this.data.settings;
	}

	updateSettings(patch) {
		this.data.settings = normalizeSettings({ ...this.data.settings, ...patch });
		this.save();
		return this.data.settings;
	}

	selectedProfile() {
		const profiles = this.data.profiles;
		return profiles.find(p => p.id === this.data.selectedProfileId) || profiles[0] || null;
	}

	addProfile(fields) {
		const existing = this.data.profiles.find(p => samePath(p.gameDir, fields.gameDir));
		if (existing) {
			this.data.selectedProfileId = existing.id;
			this.save();
			return existing;
		}
		const profile = normalizeProfile({ ...fields, id: crypto.randomUUID() });
		this.data.profiles.push(profile);
		if (!this.data.selectedProfileId || !this.data.profiles.some(p => p.id === this.data.selectedProfileId)) {
			this.data.selectedProfileId = profile.id;
		}
		this.save();
		return profile;
	}

	updateProfile(id, patch) {
		const index = this.data.profiles.findIndex(p => p.id === id);
		if (index < 0) {
			throw new Error('profile not found');
		}
		const { id: ignored, ...rest } = patch || {};
		this.data.profiles[index] = normalizeProfile({ ...this.data.profiles[index], ...rest, id });
		this.save();
		return this.data.profiles[index];
	}

	removeProfile(id) {
		this.data.profiles = this.data.profiles.filter(p => p.id !== id);
		if (this.data.selectedProfileId === id) {
			this.data.selectedProfileId = this.data.profiles[0] ? this.data.profiles[0].id : '';
		}
		this.save();
	}

	selectProfile(id) {
		if (!this.data.profiles.some(p => p.id === id)) {
			throw new Error('profile not found');
		}
		this.data.selectedProfileId = id;
		this.save();
	}

	setLastTab(tab) {
		this.data.lastTab = String(tab || 'home');
		this.save();
	}

	setWelcomeDone() {
		this.data.welcomeDone = true;
		this.save();
	}
}

function normalizeProfile(raw) {
	return {
		id: String(raw.id || crypto.randomUUID()),
		name: String(raw.name || '').slice(0, 80),
		gameDir: path.resolve(String(raw.gameDir)),
		source: raw.source === 'steam' ? 'steam' : 'manual',
		steamBranch: typeof raw.steamBranch === 'string' ? raw.steamBranch : '',
		launchViaSteam: raw.launchViaSteam === true,
		extraArgs: typeof raw.extraArgs === 'string' ? raw.extraArgs : '',
	};
}

function pick(value, allowed, fallback) {
	return allowed.includes(value) ? value : fallback;
}

function normalizeSettings(raw) {
	const source = raw && typeof raw === 'object' ? raw : {};
	const keep = Number.parseInt(source.snapshotKeep, 10);
	return {
		windowMode: pick(source.windowMode, ['default', 'fullscreen', 'windowed'], DEFAULT_SETTINGS.windowMode),
		renderer: pick(source.renderer, ['default', 'vulkan', 'd3d12', 'opengl3'], DEFAULT_SETTINGS.renderer),
		logLevel: pick(source.logLevel, ['off', 'info', 'debug', 'very_debug'], DEFAULT_SETTINGS.logLevel),
		afterLaunch: pick(source.afterLaunch, ['keep', 'minimize', 'close'], DEFAULT_SETTINGS.afterLaunch),
		language: pick(source.language, ['auto', 'zh', 'en'], DEFAULT_SETTINGS.language),
		extraArgs: typeof source.extraArgs === 'string' ? source.extraArgs : '',
		saveRoot: typeof source.saveRoot === 'string' ? source.saveRoot : '',
		saveAccount: typeof source.saveAccount === 'string' ? source.saveAccount : '',
		snapshotBeforeLaunch: source.snapshotBeforeLaunch === undefined ? DEFAULT_SETTINGS.snapshotBeforeLaunch : source.snapshotBeforeLaunch === true,
		snapshotKeep: Number.isFinite(keep) ? Math.min(50, Math.max(1, keep)) : DEFAULT_SETTINGS.snapshotKeep,
	};
}

function samePath(a, b) {
	const left = path.resolve(a);
	const right = path.resolve(b);
	return process.platform === 'win32' ? left.toLowerCase() === right.toLowerCase() : left === right;
}

module.exports = { LauncherConfig, DEFAULT_SETTINGS, normalizeSettings, samePath };
