'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const call = (channel, ...args) => ipcRenderer.invoke(channel, ...args).then(result => {
	if (!result.ok) {
		throw new Error(result.error);
	}
	return result.value;
});

contextBridge.exposeInMainWorld('launcher', {
	state: () => call('state'),
	setLastTab: tab => call('ui:lastTab', tab),
	setWelcomeDone: () => call('ui:welcomeDone'),
	updateSettings: patch => call('settings:update', patch),
	detectSteam: () => call('profiles:detect'),
	addFolder: () => call('profiles:addFolder'),
	selectProfile: id => call('profiles:select', id),
	updateProfile: (id, patch) => call('profiles:update', id, patch),
	removeProfile: id => call('profiles:remove', id),
	pickSaveRoot: () => call('saves:pickRoot'),
	createSnapshot: () => call('saves:snapshot'),
	restoreSnapshot: name => call('saves:restore', name),
	deleteSnapshot: name => call('saves:deleteSnapshot', name),
	setModsMaster: enabled => call('mods:setMaster', enabled),
	setModEnabled: (id, enabled) => call('mods:setEnabled', id, enabled),
	fixModOrder: () => call('mods:fixOrder'),
	deleteMod: (id, relativePath) => call('mods:delete', id, relativePath),
	prepareModImport: kind => call('mods:prepareImport', kind),
	commitModImport: token => call('mods:commitImport', token),
	cancelModImport: token => call('mods:cancelImport', token),
	open: (target, profileId) => call('shell:open', target, profileId),
	openExternal: url => call('shell:external', url),
	launch: () => call('game:launch'),
	onGameExited: callback => ipcRenderer.on('game-exited', () => callback()),
});
