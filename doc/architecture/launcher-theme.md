# 启动器主题：喵喵零和小鱼的小屋

Android 启动器、iPad 原生启动器（`sts2-ios/ios-export/launcher/`）与 Windows 启动器（`windows/`）使用同一套前端：同一张主页插画、夜间小屋配色、描边标题和代码绘制的吉祥物。

## 布局

- **宽屏（横屏且宽度 ≥ 720dp）**：左侧插画侧栏（插画 logo、回到小屋 / 游戏管理 / 本地 MOD / 版本管理 / 设置 / 关于、底部插画明信片），右侧为页面内容。
- **回到小屋**：宽屏且宽高比 ≥ 1.25 时，整幅插画铺满屏幕，插画里画好的「存档管理 / 本地 MOD / 联机小屋 / 设置 / 开始游戏」上覆盖透明的真实按钮；热区像素坐标与 iPad 一致（插画 1536×1024，按铺满缩放后换算）。未导入游戏本体时，开始按钮上方显示可点击的状态提示，点击进入导入流程。
- **窄屏（手机竖屏）**：顶部胶囊标签（小屋 / MOD / 版本 / 设置 / 关于）。「小屋」是游戏管理页：插画 logo、明信片插画卡片、吉祥物、「进屋开玩」奶油色主按钮，以及原有的 MOD/存档状态和维护工具。
- 子页面与首次向导都叠在同一张插画的模糊压暗版本上。

热区映射：存档管理 → 设置·存档分段；本地 MOD → MOD 页；联机小屋 → 设置·系统分段（含联机设置）；设置 → 设置页；开始游戏 → 正常启动流程（含兼容包推荐等检查）。

## 代码位置

| 文件 | 作用 |
| --- | --- |
| `android/src/com/godot/game/CottageTheme.java` | 配色常量、插画裁片与模糊背景、描边标题、页面标题标签、主/次/侧栏按钮、猫爪图标、吉祥物 `MascotView`。改配色或形象只改这里。 |
| `android/src/com/godot/game/CottageHomeStage.java` | 插画主页与透明热区、状态提示。 |
| `android/src/com/godot/game/GameSettingsActivity.java` | 外壳：侧栏/顶部标签、主页切换、背景层、内容区 insets。 |
| `android/src/com/godot/game/ExtraSettingsUi.java` | 通用组件配色已映射到 `CottageTheme`，原有各页面随之换肤。 |
| `android/res/drawable-nodpi/launcher_home.jpg` | 主页插画（与 iPad 启动器相同）。 |
| `android/res/values*/strings_cottage.xml` | 主题文案（中文与英文默认）。 |

### Windows 启动器

`windows/` 是 Electron 应用，界面用 HTML/CSS 复刻同一套主题，布局阈值与 Android 相同（以窗口 CSS 像素代替 dp）：

| 文件 | 作用 |
| --- | --- |
| `windows/src/renderer/styles.css` | 配色 token（与 `CottageTheme` 常量一一对应）、描边标题、侧栏/胶囊标签、卡片、按钮。 |
| `windows/src/renderer/app.js` | 外壳与各页面；`HOTSPOTS`、`BRAND_RECT`、`POSTCARD_RECT`、`CONTENT_TOP/BOTTOM` 与 `CottageHomeStage` / `CottageTheme` 相同，插画裁片用 CSS 背景定位。 |
| `windows/src/renderer/mascot.js` | 吉祥物与猫爪的 SVG 版本，坐标与 `MascotView` / `PawDrawable` 相同。 |
| `windows/src/renderer/i18n.js` | 主题文案（中文 / 英文），与 `strings_cottage.xml` 用语一致。 |

插画、图标和 Material Symbols 字体不复制进 `windows/`，构建时由 `windows/scripts/prepare-assets.js` 从 `android/res/` 拷贝。改插画或热区时三端一起改。

插画由项目作者为本启动器生成，不含游戏素材；吉祥物为纯代码绘制的原创形象。
