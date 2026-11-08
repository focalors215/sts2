'use strict';

/*
 * 本机加密保存的凭据（AI 接口 key、WebDAV 密码、Nexus API key、Steam refresh token）。
 * 对齐 Android EncryptedSharedPreferences：用 Electron safeStorage（Windows 为 DPAPI，绑定当前用户），
 * 加密不可用时拒绝保存，不退回明文；读取失败不清除原文件。值只在主进程里解密，不进日志、导出或渲染进程。
 */
const fs = require('fs');
const path = require('path');
const { log } = require('./logger');

class SecretStore {
	/** cipher：{ isEncryptionAvailable(), encryptString(text) → Buffer, decryptString(Buffer) → text } */
	constructor(file, cipher) {
		this.file = file;
		this.cipher = cipher;
	}

	readAll() {
		let raw;
		try {
			raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
		} catch (error) {
			if (error.code === 'ENOENT') {
				return {};
			}
			log().e('app', `读取加密凭据文件失败（未清除原文件）: ${this.file}`, error);
			throw new Error('secret_store_unreadable');
		}
		return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
	}

	get(key) {
		const all = this.readAll();
		if (typeof all[key] !== 'string' || !all[key]) {
			return '';
		}
		try {
			const value = this.cipher.decryptString(Buffer.from(all[key], 'base64'));
			log().addSecret(value);
			return value;
		} catch (error) {
			log().e('app', `解密凭据 ${key} 失败（未清除原值）`, error);
			throw new Error('secret_store_unreadable');
		}
	}

	has(key) {
		try {
			const all = this.readAll();
			return typeof all[key] === 'string' && all[key] !== '';
		} catch (error) {
			return false; // readAll 已记日志。
		}
	}

	set(key, value) {
		const all = this.readAll();
		if (!value) {
			delete all[key];
		} else {
			if (!this.cipher.isEncryptionAvailable()) {
				log().e('app', `系统加密不可用，拒绝保存凭据 ${key}`);
				throw new Error('secret_store_unavailable');
			}
			log().addSecret(value);
			all[key] = this.cipher.encryptString(value).toString('base64');
		}
		fs.mkdirSync(path.dirname(this.file), { recursive: true });
		const temp = `${this.file}.${process.pid}.tmp`;
		fs.writeFileSync(temp, JSON.stringify(all), { encoding: 'utf8', mode: 0o600 });
		fs.renameSync(temp, this.file);
	}
}

module.exports = { SecretStore };
