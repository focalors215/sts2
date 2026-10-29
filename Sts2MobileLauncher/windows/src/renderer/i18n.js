'use strict';

(function () {
	// 文案：与 Android strings_cottage.xml / iPad 启动器同一套主题用语。
	const STRINGS = {
		zh: {
			theme_name: '喵喵零和小鱼的小屋',
			nav_home: '回到小屋', nav_dashboard: '游戏管理', nav_mods: '本地 MOD', nav_versions: '版本管理', nav_settings: '设置', nav_about: '关于',
			tab_home: '小屋', tab_mods: 'MOD', tab_versions: '版本', tab_settings: '设置', tab_about: '关于',
			hotspots: ['存档管理', '本地 MOD', '联机小屋', '设置', '开始游戏'],
			postcard: '喵喵零和小鱼盖着毯子看书',
			hero_subtitle: '杀戮尖塔 2 · 今天也一起爬塔喵～',
			start_game: '进屋开玩',
			launch_disabled: '还不能开玩',
			status_missing: '还没找到游戏本体，点这里添加',
			status_broken: '游戏目录缺少文件，点这里检查',
			tagline_dashboard: '今天也一起爬塔喵～', tagline_mods: '给小屋添点新花样', tagline_versions: '整理小屋的书架', tagline_settings: '小屋的小角落', tagline_about: '关于这间小屋',
			ready_line: '{version} · 准备就绪', not_ready_line: '游戏目录还没准备好', no_profile_line: '还没有添加游戏目录',
			mods_card: 'MOD', mods_value: '{enabled} / {total} 已启用', mods_on: 'MOD 加载已开启', mods_off: 'MOD 加载已关闭', mods_none: '尚未安装 MOD',
			saves_card: '存档', saves_value: '{count} 个快照', saves_account: '账号 {id}', saves_none: '还没有找到存档',
			maintenance: '维护工具', advanced: '高级工具',
			act_open_game: '游戏目录', act_open_mods: 'MOD 目录', act_open_saves: '存档目录', act_snapshot: '存档快照',
			act_profiles: '启动配置', act_validate: '校验文件', act_logs: '游戏日志', act_data: '启动器数据',
			profile_chip: '当前：{name}', profile_chip_none: '未选择游戏',
			// MOD
			mods_master: 'MOD 总开关', mods_master_desc: '写入当前存档账号的 settings.save（mod_settings.mods_enabled），下次启动游戏生效。',
			mods_search: '搜索 MOD…', import_zip: '导入 ZIP', import_folder: '导入文件夹', open_folder: '打开目录', refresh: '刷新',
			filter_all: '全部', filter_enabled: '已启用', filter_disabled: '已禁用', filter_problems: '有问题',
			mods_empty: '小屋里还没有 MOD。导入一个 ZIP 或文件夹试试吧。', mods_no_match: '没有符合条件的 MOD。',
			mods_no_profile: '先在「版本管理」添加游戏目录，MOD 会安装到游戏目录下的 mods 文件夹。',
			mods_no_settings: '还没找到 settings.save：先正常启动一次游戏，之后才能在这里切换 MOD 开关（导入和删除不受影响）。',
			mod_desc_none: '这个 MOD 没有写描述。', mod_path: '清单', mod_author: '作者', mod_deps: '依赖', mod_min_game: '最低游戏版本', mod_delete: '删除',
			mod_delete_title: '删除 MOD', mod_delete_body: '确定删除「{name}」吗？会删除它在 mods 目录里的文件，无法撤销。',
			problems_title: 'MOD 问题', problems_fix: '自动修复加载顺序', problems_none: '没有发现问题。',
			w_missing_dependency: '缺少依赖 {target}', w_disabled_dependency: '依赖 {target} 未启用', w_order: '加载顺序：{target} 应排在它前面',
			w_missing_pck: '清单声明有 PCK，但找不到 {target}', w_missing_dll: '清单声明有 DLL，但找不到 {target}', w_no_payload: '没有找到同名 DLL / PCK',
			w_duplicate_id: '存在多个同 ID（{target}）的 MOD，开关会连体', w_game_version: '需要游戏版本 ≥ {target}',
			import_title: '导入 MOD', import_will_install: '将安装到 mods/{folder}：',
			import_conflict: '已安装同 ID 的 MOD。两个同 ID 项目会出现「连体」：任何一个开关都会同时影响两者。',
			import_keep_old: '保留原 MOD', import_use_new: '使用新 MOD', import_overwrite: '下列已有文件会被覆盖：', import_confirm: '导入', import_replace: '仍然覆盖',
			imported: '已导入：{names}', no_manifest: '没有在里面找到 MOD 清单（含 id 的 .json）。',
			// 版本
			versions_notice: 'Windows 直接运行 PC 原版，不需要 Android 兼容包。这里管理游戏目录（启动配置）：可以同时登记多个目录，比如正式版和测试分支。',
			detect_steam: '自动检测 Steam', add_folder: '添加游戏目录', detect_none: '没有在 Steam 库里找到杀戮尖塔 2。可以手动添加游戏目录。', detect_done: '找到 {count} 个 Steam 安装',
			profiles_empty: '书架还是空的：自动检测 Steam，或手动选择游戏目录。',
			profile_current: '当前', profile_select: '设为当前', profile_edit: '编辑', profile_open: '打开目录', profile_remove: '移除',
			profile_version: '版本', profile_branch: '分支', profile_path: '目录', profile_dll: 'sts2.dll', profile_missing: '缺少：{files}', profile_ready: '文件完整',
			profile_source_steam: 'Steam', profile_source_manual: '手动目录', profile_launch: '启动方式', profile_via_steam: '通过 Steam 启动', profile_via_exe: '直接运行 exe',
			edit_title: '编辑启动配置', edit_name: '名称', edit_via_steam: '通过 Steam 启动', edit_via_steam_desc: '默认关闭：直接运行游戏并跳过 Steam 初始化；开启后保留 Steam 登录、云存档和联机。', edit_args: '额外启动参数（仅此配置）',
			remove_title: '移除启动配置', remove_body: '只从启动器里移除「{name}」，不会删除游戏文件。',
			// 设置
			seg_display: '画面', seg_controls: '操作', seg_saves: '存档', seg_system: '系统',
			set_window: '窗口模式', set_window_desc: '启动时传给游戏的窗口参数；「跟随游戏」使用游戏内设置。',
			window_default: '跟随游戏', window_fullscreen: '全屏', window_windowed: '窗口化',
			set_renderer: '渲染器', set_renderer_desc: '强制 Godot 使用指定的渲染后端，遇到黑屏或闪退时可以换一个试试。',
			renderer_default: '默认', renderer_vulkan: 'Vulkan', renderer_d3d12: 'Direct3D 12', renderer_opengl3: 'OpenGL（兼容）',
			set_after: '启动游戏后', set_after_desc: '游戏启动后启动器窗口怎么处理。',
			after_keep: '保持打开', after_minimize: '最小化', after_close: '关闭启动器',
			set_language: '启动器语言', language_auto: '跟随系统', language_zh: '中文', language_en: 'English',
			set_save_root: '存档目录', set_save_root_desc: '游戏的 user:// 目录，默认 %APPDATA%\\SlayTheSpire2。', change: '更改', reset_default: '恢复默认', open: '打开',
			set_account: '存档账号', set_account_desc: '含 settings.save 的目录；MOD 开关和快照都作用于这个账号。', account_auto: '自动（最近使用）', account_none: '未找到',
			set_snapshot_launch: '启动前自动快照', set_snapshot_launch_desc: '每次启动游戏前把当前账号的存档打包备份。',
			set_snapshot_keep: '自动快照保留数量', set_snapshot_keep_desc: '手动快照不会被自动清理。',
			snapshots: '存档快照', snapshot_now: '立即创建快照', snapshots_empty: '还没有快照。', restore: '恢复', delete: '删除',
			snapshot_created: '已创建快照', snapshot_restored: '已恢复快照（恢复前已自动备份当前存档）',
			restore_title: '恢复快照', restore_body: '会用快照 {name} 替换当前账号的存档。恢复前会先自动备份当前存档。确定吗？',
			reason_manual: '手动', 'reason_before-launch': '启动前', 'reason_before-restore': '恢复前',
			set_log: '日志等级', set_log_desc: '转换为游戏的 -log 参数（Generic / Network / Actions / GameSync / VisualSync）。',
			log_off: '关闭', log_info: '信息', log_debug: '调试', log_very_debug: '详细调试',
			set_args: '额外启动参数', set_args_desc: '附加在每次启动的命令行末尾，例如 --verbose。', set_args_placeholder: '例如 --verbose',
			network_title: '联机小屋', network_body: 'Windows 版直接使用原版联机（Steam 好友 / 大厅），不需要 Android 的本地联机补丁。和手机上的小伙伴联机时，双方游戏版本和启用的玩法 MOD 需要一致。',
			set_data: '启动器数据目录', set_data_desc: '启动配置、快照和导入缓存都在这里。',
			// 关于
			about_body: '这是杀戮尖塔 2 的 Windows 小屋启动器，和 Android、iPad 启动器共用同一套「喵喵零和小鱼的小屋」前端：同一张插画、夜间小屋配色、描边标题和代码绘制的吉祥物。',
			about_note: '启动器不包含任何游戏文件，请使用你自己在 Steam 上拥有的杀戮尖塔 2。插画由项目作者为启动器生成，不含游戏素材；吉祥物为纯代码绘制的原创形象。',
			about_version: '启动器版本 {version}', about_repo: '项目主页',
			// 欢迎
			welcome_title: '欢迎来到小屋', welcome_body: '先告诉小屋你的杀戮尖塔 2 装在哪里吧。安装了 Steam 版的话，点「自动检测」就好。', welcome_enter: '进入小屋', welcome_skip: '稍后再说',
			// 通用
			cancel: '取消', ok: '好', save: '保存', close: '关闭', choose: '请选择',
			launching: '正在启动…', launched_steam: '已通过 Steam 启动游戏', launched_exe: '游戏已启动',
			err_no_profile: '还没有添加游戏目录', err_game_not_ready: '游戏目录缺少必需文件', err_game_running: '游戏正在运行，请先退出游戏', err_no_settings_save: '没有找到 settings.save，请先启动一次游戏',
			error: '出错了：{message}', game_exited: '游戏已退出，欢迎回到小屋',
		},
		en: {
			theme_name: "Meow Zero & Little Fish's Cottage",
			nav_home: 'Cottage', nav_dashboard: 'Game', nav_mods: 'Local Mods', nav_versions: 'Versions', nav_settings: 'Settings', nav_about: 'About',
			tab_home: 'Cottage', tab_mods: 'Mods', tab_versions: 'Versions', tab_settings: 'Settings', tab_about: 'About',
			hotspots: ['Saves', 'Local mods', 'Multiplayer', 'Settings', 'Start game'],
			postcard: 'Meow Zero and Little Fish reading under a blanket',
			hero_subtitle: "Slay the Spire 2 · Let's climb the spire together today",
			start_game: 'Come on in',
			launch_disabled: 'Not ready yet',
			status_missing: 'Game not found yet. Click here to add it.',
			status_broken: 'The game folder is missing files. Click to check.',
			tagline_dashboard: 'Today we climb together', tagline_mods: 'Something new for the cottage', tagline_versions: 'Tidy up the cottage bookshelf', tagline_settings: 'A cozy corner of the cottage', tagline_about: 'About this little cottage',
			ready_line: '{version} · ready', not_ready_line: 'The game folder is not ready', no_profile_line: 'No game folder added yet',
			mods_card: 'Mods', mods_value: '{enabled} / {total} enabled', mods_on: 'Mod loading on', mods_off: 'Mod loading off', mods_none: 'No mods installed',
			saves_card: 'Saves', saves_value: '{count} snapshots', saves_account: 'Account {id}', saves_none: 'No saves found yet',
			maintenance: 'Maintenance', advanced: 'Advanced',
			act_open_game: 'Game folder', act_open_mods: 'Mods folder', act_open_saves: 'Save folder', act_snapshot: 'Snapshot',
			act_profiles: 'Profiles', act_validate: 'Verify files', act_logs: 'Game logs', act_data: 'Launcher data',
			profile_chip: 'Current: {name}', profile_chip_none: 'No game selected',
			mods_master: 'Mod master switch', mods_master_desc: 'Written to settings.save (mod_settings.mods_enabled) of the current save account. Takes effect next launch.',
			mods_search: 'Search mods…', import_zip: 'Import ZIP', import_folder: 'Import folder', open_folder: 'Open folder', refresh: 'Refresh',
			filter_all: 'All', filter_enabled: 'Enabled', filter_disabled: 'Disabled', filter_problems: 'Problems',
			mods_empty: 'No mods in the cottage yet. Try importing a ZIP or folder.', mods_no_match: 'No mods match.',
			mods_no_profile: 'Add a game folder under Versions first. Mods are installed into its mods folder.',
			mods_no_settings: 'settings.save not found. Launch the game once before toggling mods here (import and delete still work).',
			mod_desc_none: 'This mod has no description.', mod_path: 'Manifest', mod_author: 'Author', mod_deps: 'Dependencies', mod_min_game: 'Min game version', mod_delete: 'Delete',
			mod_delete_title: 'Delete mod', mod_delete_body: 'Delete "{name}"? Its files in the mods folder will be removed. This cannot be undone.',
			problems_title: 'Mod problems', problems_fix: 'Fix load order', problems_none: 'No problems found.',
			w_missing_dependency: 'Missing dependency {target}', w_disabled_dependency: 'Dependency {target} is disabled', w_order: 'Load order: {target} should come first',
			w_missing_pck: 'Manifest declares a PCK but {target} is missing', w_missing_dll: 'Manifest declares a DLL but {target} is missing', w_no_payload: 'No matching DLL / PCK found',
			w_duplicate_id: 'Several mods share id {target}; their switches are linked', w_game_version: 'Requires game ≥ {target}',
			import_title: 'Import mod', import_will_install: 'Will be installed to mods/{folder}:',
			import_conflict: 'A mod with the same id is installed. Two items with one id are linked: either switch affects both.',
			import_keep_old: 'Keep old mod', import_use_new: 'Use new mod', import_overwrite: 'These existing files will be overwritten:', import_confirm: 'Import', import_replace: 'Overwrite anyway',
			imported: 'Imported: {names}', no_manifest: 'No mod manifest (.json with an id) found inside.',
			versions_notice: 'Windows runs the original PC game directly — no Android compat pack needed. Manage game folders (launch profiles) here; you can register several, e.g. stable and beta.',
			detect_steam: 'Detect Steam', add_folder: 'Add game folder', detect_none: 'Slay the Spire 2 was not found in your Steam libraries. Add the folder manually.', detect_done: 'Found {count} Steam install(s)',
			profiles_empty: 'The bookshelf is empty: detect Steam or choose a game folder.',
			profile_current: 'Current', profile_select: 'Use this', profile_edit: 'Edit', profile_open: 'Open folder', profile_remove: 'Remove',
			profile_version: 'Version', profile_branch: 'Branch', profile_path: 'Folder', profile_dll: 'sts2.dll', profile_missing: 'Missing: {files}', profile_ready: 'Files complete',
			profile_source_steam: 'Steam', profile_source_manual: 'Manual folder', profile_launch: 'Launch', profile_via_steam: 'Launch via Steam', profile_via_exe: 'Run exe directly',
			edit_title: 'Edit profile', edit_name: 'Name', edit_via_steam: 'Launch via Steam', edit_via_steam_desc: 'Off by default: run the game directly and skip Steam initialization. Turn on for Steam login, cloud saves and multiplayer.', edit_args: 'Extra launch arguments (this profile only)',
			remove_title: 'Remove profile', remove_body: 'Only removes "{name}" from the launcher. Game files are not deleted.',
			seg_display: 'Display', seg_controls: 'Controls', seg_saves: 'Saves', seg_system: 'System',
			set_window: 'Window mode', set_window_desc: 'Window argument passed at launch. "Game default" uses the in-game setting.',
			window_default: 'Game default', window_fullscreen: 'Fullscreen', window_windowed: 'Windowed',
			set_renderer: 'Renderer', set_renderer_desc: 'Force a Godot rendering backend. Try another one on black screens or crashes.',
			renderer_default: 'Default', renderer_vulkan: 'Vulkan', renderer_d3d12: 'Direct3D 12', renderer_opengl3: 'OpenGL (compatibility)',
			set_after: 'After launching', set_after_desc: 'What the launcher window does once the game starts.',
			after_keep: 'Stay open', after_minimize: 'Minimize', after_close: 'Close launcher',
			set_language: 'Launcher language', language_auto: 'System', language_zh: '中文', language_en: 'English',
			set_save_root: 'Save folder', set_save_root_desc: "The game's user:// folder. Default %APPDATA%\\SlayTheSpire2.", change: 'Change', reset_default: 'Default', open: 'Open',
			set_account: 'Save account', set_account_desc: 'Folder containing settings.save. Mod switches and snapshots apply to it.', account_auto: 'Automatic (most recent)', account_none: 'None found',
			set_snapshot_launch: 'Snapshot before launch', set_snapshot_launch_desc: 'Back up the current account before every launch.',
			set_snapshot_keep: 'Automatic snapshots to keep', set_snapshot_keep_desc: 'Manual snapshots are never pruned.',
			snapshots: 'Save snapshots', snapshot_now: 'Create snapshot', snapshots_empty: 'No snapshots yet.', restore: 'Restore', delete: 'Delete',
			snapshot_created: 'Snapshot created', snapshot_restored: 'Snapshot restored (current saves were backed up first)',
			restore_title: 'Restore snapshot', restore_body: 'Replace the current account saves with {name}? Current saves are backed up first.',
			reason_manual: 'Manual', 'reason_before-launch': 'Before launch', 'reason_before-restore': 'Before restore',
			set_log: 'Log level', set_log_desc: 'Converted to the game -log arguments (Generic / Network / Actions / GameSync / VisualSync).',
			log_off: 'Off', log_info: 'Info', log_debug: 'Debug', log_very_debug: 'Very debug',
			set_args: 'Extra launch arguments', set_args_desc: 'Appended to every launch, e.g. --verbose.', set_args_placeholder: 'e.g. --verbose',
			network_title: 'Multiplayer cottage', network_body: 'The Windows version uses the original multiplayer (Steam friends / lobbies); the Android LAN patch is not needed. To play with friends on phones, keep game versions and gameplay mods identical.',
			set_data: 'Launcher data folder', set_data_desc: 'Profiles, snapshots and import cache live here.',
			about_body: "The Windows cottage launcher for Slay the Spire 2. It shares the \"Meow Zero & Little Fish's Cottage\" front end with the Android and iPad launchers: same illustration, night palette, outlined titles and code-drawn mascots.",
			about_note: 'The launcher ships no game files; use the copy of Slay the Spire 2 you own on Steam. The illustration was made for this launcher and contains no game assets; the mascots are original, drawn in code.',
			about_version: 'Launcher version {version}', about_repo: 'Project page',
			welcome_title: 'Welcome to the cottage', welcome_body: 'Tell the cottage where Slay the Spire 2 lives. With the Steam version, just click Detect.', welcome_enter: 'Enter the cottage', welcome_skip: 'Later',
			cancel: 'Cancel', ok: 'OK', save: 'Save', close: 'Close', choose: 'Choose',
			launching: 'Launching…', launched_steam: 'Launched through Steam', launched_exe: 'Game started',
			err_no_profile: 'No game folder added yet', err_game_not_ready: 'The game folder is missing required files', err_game_running: 'The game is running. Quit it first.', err_no_settings_save: 'settings.save not found. Launch the game once first.',
			error: 'Something went wrong: {message}', game_exited: 'Game closed. Welcome back to the cottage',
		},
	};

	let language = 'zh';

	function setLanguage(setting) {
		if (setting === 'zh' || setting === 'en') {
			language = setting;
		} else {
			language = /^zh/i.test(navigator.language || '') ? 'zh' : 'en';
		}
		document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
	}

	function t(key, params) {
		let value = STRINGS[language][key];
		if (value === undefined) {
			value = STRINGS.zh[key];
		}
		if (value === undefined) {
			return key;
		}
		if (typeof value === 'string' && params) {
			return value.replace(/\{(\w+)\}/g, (match, name) => (params[name] !== undefined ? String(params[name]) : match));
		}
		return value;
	}

	window.i18n = { t, setLanguage };
})();
