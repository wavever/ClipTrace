<p align="center">
  <img src="ClipTrace/Assets.xcassets/AppLogo.imageset/AppLogo@2x.png" width="96" alt="剪迹 logo" />
</p>

<h1 align="center">剪迹</h1>

<p align="center">
  <a href="README.md">English</a> · <strong>中文</strong>
</p>

<p align="center">
  轻量级 macOS 剪贴板历史管理工具，内置本地语义搜索与 MCP AI 集成。
</p>

---

## 预览

<p align="center">
  <img src="docs/screenshots/main.png" alt="主界面" width="720" />
  <br/>
  <em>主界面 — 历史记录、全文与语义搜索、标签</em>
</p>

<p align="center">
  <img src="docs/screenshots/stats.png" alt="活跃统计" width="720" />
  <br/>
  <em>活跃统计 — 每日复制次数与年度热力图</em>
</p>

<p align="center">
  <img src="docs/screenshots/mcp.png" alt="MCP 集成" width="720" />
  <br/>
  <em>MCP 服务器 — 接入 Claude Desktop / Code / Cursor</em>
</p>

## 功能特性

### 核心
- **自动监听** — 实时捕获文字、图片、视频、文件、链接、富文本
- **一键复制** — 双击条目即可写回剪贴板
- **重复刷新** — 复制已有内容时自动浮到顶部，不产生重复
- **清理末尾空白** — 可选去除写回时的末尾空格/换行
- **录屏隐身** — 窗口不出现在录屏/屏幕共享中
- **全局快捷键** — `⌘⇧V` 呼出主窗口，`⌘N` 新建片段

### 整理
- **收藏与置顶** — 收藏常用条目，置顶自动浮顶，支持折叠
- **标签** — 每条可添加/移除标签，搜索栏支持标签自动补全
- **多选合并** — 选中 2+ 条同类型条目，自定义分隔符合并
- **垃圾桶** — 软删除，可恢复/彻底删除，支持自动清理

### 智能搜索
- **全文搜索** — 按类型筛选（文字/图片/视频/文件/链接/富文本）
- **语义搜索** — 基于 Apple NLEmbedding，完全离线
- **标签搜索** — 每个词都是标签候选，支持自动补全
- **无结果回退** — 语义无匹配时自动回退关键词

### 预览与内容感知
- **富预览面板** — hover 即可预览
- **智能解析** — 自动识别时间戳、Base64、JSON
- **视频预览** — 可选首帧缩略图或内联播放器（支持静音）
- **链接净化** — 复制时自动剥离 28+ 跟踪参数

### 片段
- **手动创建** — `⌘N` 打开编辑器，保存后自动置顶并进入语义索引

### 导出与统计
- **JSON 导出** — 按类型、时间范围、收藏/置顶筛选
- **复制统计** — 每日计数、14 天柱状图、GitHub 风格热力图

### AI 集成（MCP Server）

应用 binary 同时是一个 MCP stdio 服务，可接入 Claude Desktop / Claude Code / Cursor：

```json
{
  "mcpServers": {
    "clipboard": {
      "command": "/Applications/ClipTrace.app/Contents/MacOS/ClipTrace",
      "args": ["--mcp"]
    }
  }
}
```

| 工具 | 参数 | 用途 |
|---|---|---|
| `search_clipboard` | `query`, `limit?`, `semantic?` | 关键词或语义搜索 |
| `list_recent` | `limit?`, `type?` | 最近 N 条，可按类型筛选 |
| `get_clip` | `id` | 获取单条完整内容与元数据 |

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Xcode 15.0+ / Swift 5.9+

## 构建运行

**Xcode：** 打开 `ClipTrace.xcodeproj`，选择 "My Mac"，点击运行。

**命令行：**
```bash
xcodebuild -project ClipTrace.xcodeproj -scheme ClipTrace -configuration Debug build
```

### 代码签名（首次配置）

构建使用**固定的自签名证书**，这样 macOS 才能在重新构建和更新后保留辅助功能权限。
若没有固定签名身份，权限会在每次构建后被静默失效（系统设置里的开关仍是开着的，
但 App 会不断提示「想要使用辅助功能控制这台电脑」）。运行一次以下脚本即可生成并
安装证书：

```bash
scripts/generate-signing-cert.sh
```

脚本还会打印 `SIGNING_CERT_P12_BASE64` 和 `SIGNING_CERT_PASSWORD` 两个值，
将其添加为 GitHub Actions Secret，发布的 DMG 就会用同一身份签名。没有证书的
贡献者可以用 `CODE_SIGNING_ALLOWED=NO` 进行无签名构建。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘⇧V` | 打开主窗口 |
| `⌘,` | 打开设置 |
| `⌘N` | 新建片段 |
| `⌘⏎` | 保存片段 |
| `Esc` | 关闭预览 / 返回 / 取消 |

## 隐私

- 所有数据仅存储在本地（SwiftData / SQLite）
- 语义搜索使用 Apple NLEmbedding，完全离线
- MCP server 本地运行，不主动联网
- 无分析、无遥测、不收集任何数据

## 许可证

MIT
