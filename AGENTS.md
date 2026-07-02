# AGENT.md

给 AI 助手（以及人类）在本仓库工作时的指引。**构建、发布、改 UI 之前先读这份。**

## 这是什么

**剪迹 / ClipTrace** —— 原生 macOS 菜单栏剪贴板管理器。

- SwiftUI + SwiftData (SQLite)，macOS 14.0+，Swift 5（Xcode 16）。
- Bundle id `com.wavever.cliptrace`；仓库 `wavever/ClipTrace`。
- 完全本地 / 离线：语义搜索用 Apple `NLEmbedding`，OCR 用 `Vision`，本地 MCP
  服务走 stdio。无遥测、无网络请求（仅 Sparkle 更新检查除外）。
- 依赖（SPM）：**Sparkle**（自动更新）、**KeyboardShortcuts**（全局快捷键）。

### 目录结构

```
ClipTrace/
  Models/       SwiftData @Model 类型 + 偏好存储（AppearancePreferences 等）
  ViewModels/   ClipboardViewModel（列表/搜索/选择的核心）
  Views/        SwiftUI 视图 + Theme.swift（设计系统）
  Services/     单例：ClipboardMonitor、QuickPasteController、AutoPasteService、
                ToastCenter、Localization、MCPServer、UpdaterService 等
scripts/        generate-signing-cert.sh（一次性签名配置）
.github/workflows/  ci.yml（PR 构建）、release.yml（按 tag 发布）
```

约定：UI 与服务单例都是 `@MainActor`，以 `.shared` 暴露。SwiftData 统一走
`AppContainer.shared` 这唯一一个 `ModelContainer`（见 `QuickPasteController.swift`），
保证浮动面板和主窗口读写同一份数据。代码注释解释**为什么**而非做了什么——改代码时
保持同样的注释密度。

## 本地构建运行

```bash
xcodebuild -project ClipTrace.xcodeproj -scheme ClipTrace -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/ClipTrace.app
```

**准则：开发阶段，每次完成代码开发后都必须构建并把 App 运行起来。** 不要只报告编译通过；
构建失败就先修复，不算“完成”。构建成功后先杀掉旧实例，再启动刚生成的 `.app`，在真实
App 里验证：

```bash
pkill -f "ClipTrace.app/Contents/MacOS/ClipTrace" || true
open build/Build/Products/Debug/ClipTrace.app
```

若本次构建使用了不同的 `-derivedDataPath` 或 Xcode 默认 DerivedData，必须启动对应路径下
最新生成的 `ClipTrace.app`，不要启动旧产物。

本地构建会自动用 `ClipTrace Self-Signed` 身份签名（见下）。若该身份不在钥匙串里，构建会
失败——要么运行一次 `scripts/generate-signing-cert.sh`，要么用 `CODE_SIGNING_ALLOWED=NO`
做无签名构建。

## 代码签名（动签名相关的任何东西前必读）

App 使用**固定的自签名证书**（`CN = ClipTrace Self-Signed`）签名，而**不是** ad-hoc。
这是关键，不能退回 ad-hoc：

- macOS 把**辅助功能（TCC）**授权绑定在 bundle 的代码签名*指定要求（designated
  requirement）*上。ad-hoc 签名会让这个要求退化成每次构建都变的 cdhash，于是每次
  重建/更新都会静默作废授权，而系统设置里的开关还亮着 → App 不断弹「想要使用辅助功能
  控制这台电脑」。固定证书让要求变成 `identifier + 证书指纹`，在重建、更新、换机器后都
  保持不变，授权得以保留。
- `ENABLE_HARDENED_RUNTIME = NO`。真实签名（不同于 ad-hoc）会真正启用硬化运行时，进而
  打开库校验，导致启动崩溃（Xcode 16 的 `*.debug.dylib` / 框架 Team-ID 不匹配）。硬化
  运行时只有公证才需要，而免费自签名阶段并不公证。**只有在升级到 Developer ID + 公证时
  才重新开启它。**

### 规则

- **每台开发机只运行一次 `scripts/generate-signing-cert.sh`。** 它把证书装进登录钥匙串，
  并打印 CI 需要的两个 GitHub Secret。
- **绝不重新生成证书。** 新证书 = 新指纹 = 新要求 = 所有用户的辅助功能授权再次失效。脚本
  不加 `--force` 会拒绝执行。
- 项目签名设置在 `ClipTrace.xcodeproj/project.pbxproj`：Debug 和 Release 都是
  `CODE_SIGN_STYLE = Manual`、`CODE_SIGN_IDENTITY = "ClipTrace Self-Signed"`。

### 这套方案没解决的

App **未公证**（需要付费 Developer ID）。首次启动仍会有 Gatekeeper「无法验证开发者」
提示；用户需把 App 移到 `/Applications` 并执行
`xattr -dr com.apple.quarantine /Applications/ClipTrace.app`。

### 老用户一次性迁移（ad-hoc → 签名）

从未签名旧版升级上来的用户，会留下一条对不上的旧 TCC 记录（身份确实变了）。在受影响的
机器上做一次：`tccutil reset Accessibility com.wavever.cliptrace`，把 App 移到
`/Applications`，去掉 quarantine，重启，重新授权。此后所有更新都稳定保留授权。

## 发布流程

推送 `v*` tag 触发。`.github/workflows/release.yml`：

1. **导入签名证书**：从 Secret `SIGNING_CERT_P12_BASE64`、`SIGNING_CERT_PASSWORD`
   导入临时钥匙串；未设置则直接失败。
2. **Release 构建**：用 `ClipTrace Self-Signed` 签名；校验产物非 ad-hoc，且烤进去的
   版本号与 tag 一致。
3. 通过 `scripts/package_dmg.sh` 打包 `.app` 成带背景指引的 DMG（拖入 Applications
   安装），用 **Sparkle EdDSA 签名** DMG，重新生成 `appcast.xml`，发布 GitHub Release。

### 版本号 —— 重要

target 开了 `GENERATE_INFOPLIST_FILE = YES`，所以 Xcode 在构建时会从 `MARKETING_VERSION`
**重新生成** `CFBundleShortVersionString`、从 `CURRENT_PROJECT_VERSION` 重新生成
`CFBundleVersion`。因此：

- **不要**在 `ClipTrace/Info.plist` 里写版本号，也不要用 `plutil` 去改——会被生成值覆盖。
  （那两个键已被故意移除。）
- Release 构建从 git tag 传入 `MARKETING_VERSION="$VERSION"` 和
  `CURRENT_PROJECT_VERSION="$VERSION"`。`CFBundleVersion` 必须跟着版本走，否则 Sparkle
  的比较器会把运行中的 App 读成版本「1」（`> 0.9.x`），永远不提示更新。
- 本地/开发构建显示 pbxproj 里的 `MARKETING_VERSION`（仅展示用）。
- UI 从 `CFBundleShortVersionString` 读版本号（`SettingsPanelView.swift`）；不要在 Swift
  里硬编码版本字符串。

存在两个互相独立的「签名」，别混淆：**App 代码签名**（自签名证书，管 TCC/Gatekeeper）
和 **DMG 的 Sparkle EdDSA 签名**（Info.plist 里的 `SUPublicEDKey`，管更新包完整性）。

## 设计语言 / 风格规范

整体是温暖的**「纸张」质感**：奶油色纸卡漂浮在柔和的**鼠尾草（sage）**外框上，配**暖橄榄色
阴影**而非冷灰/黑。整套系统在 `ClipTrace/Views/Theme.swift`。

- **暖色、低饱和的大地色系。避免冷感/科技蓝。** sage 是验证过的默认色，连「蓝」这个 accent
  都做得更柔。
- **用设计 token，别用裸色值。** `Color.appPaper`、`.appCard`、`.appCardBorder`、
  `.appCardShadow`、`.appChipFill`、`.appMetal` 等都是会自动随明暗切换的动态 `NSColor`
  ——调用处不要再手动判断色彩模式。
- **复用现成的修饰符/样式：** `.paperCard(cornerRadius:isHovered:isSelected:)`、
  `.paperTextField(focused:)`、`PaperActionButtonStyle`（.plain/.primary/.destructive）、
  `PaperIconButtonStyle`。圆角用 continuous（控件约 7，卡片约 14）。
- **Accent 支持运行时切换**（`AccentThemeStore`，`@Observable`）。用 `Color.appAccent`，
  **绝不**用 `Color.accentColor`/`.accentColor`（在 macOS 上会解析成系统蓝）。换 accent 时
  纸张/表面语言保持不变，只有*内容*的 tint 跟随 accent。
- **外观：** 通过 `NSApp.appearance` 驱动（见 `AppearanceTheme`），不要只靠
  `.preferredColorScheme`。「跟随系统」必须清掉被强制的方案（macOS 上 SwiftUI 不会自动清）。
  不要重新引入会卡住的强制方案。

### 动效（用户对此非常挑剔）

动画要**丝滑**，绝不生硬或线性。既有惯用法：

- 高亮/转场用弹簧：`.spring(response: 0.28–0.34, dampingFraction: 0.75–0.85)`。
- 滑动选中高亮用 `interpolatingSpring`（anchor 驱动），滚动跟随通过 `onChange` 接线。
- 快速状态翻转（按压、hover）用 `.easeOut(duration: 0.08–0.15)`。
- 始终对绑定了 `value:` 的状态做动画；避免隐式/全局动画。

### 本地化

双语（简体中文 / English），可通过 `AppLanguage` 运行时切换。**所有面向用户的文案都走
`L("key")` / `L("key", args…)`**（见 `Services/Localization.swift`）——绝不硬编码展示文案。
新增时 `zh` 和 `en` 都要加。保持 `README.md` 与 `README.zh-CN.md` 同步。

## 易踩的坑

- 快速粘贴面板是无边框的 `KeyablePanel`（重写了 `canBecomeKey`）才能接收键盘事件；它会
  激活自身、再在发送合成 ⌘V 前把焦点交还给之前的前台 App（`AutoPasteService`）。
- App 写剪贴板前必须先 `markInternalWrite()`，否则重新粘贴的历史项会被顶到列表最上面。
- 不要提交 `build/`、`build-debug/`、`build-release/`、`.claude/`。
- 默认分支是 `main`；这是单人仓库，提交直接进 main。提交信息结尾带 Claude + Happy 的
  co-author trailer。
