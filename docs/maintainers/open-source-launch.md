# Open Source Launch Kit

This document is a maintainer checklist for launching Clipth as an open-source project.

## Positioning

Primary message:

> Clipth is a local-first clipboard history app for macOS and AI tools.

Longer version:

> Clipth is an open-source macOS clipboard manager with offline semantic search and a built-in MCP server, so Claude Desktop, Claude Code, Cursor, and other MCP clients can search clipboard history without uploading it to a cloud service.

Do not position it as "just another clipboard manager." Lead with:

- Local-first privacy
- Offline semantic search
- MCP integration for AI tools
- Native macOS productivity

## Pre-Launch Checklist

Repository:

- [ ] `README.md` explains the product in the first screen.
- [ ] `README.zh-CN.md` is in sync with the English README.
- [ ] `LICENSE` exists and matches the README.
- [ ] `PRIVACY.md` explains data storage, network access, semantic search, and MCP boundaries.
- [ ] `SECURITY.md` explains private reporting.
- [ ] `CONTRIBUTING.md` has a working build command.
- [ ] `ROADMAP.md` is realistic and public-facing.
- [ ] Issue templates and PR template exist.
- [ ] GitHub topics are configured.
- [ ] CI is green on `main`.

Release:

- [ ] Tag a clear first open-source release, preferably `v1.0.0`.
- [ ] DMG installs and launches on a clean macOS machine.
- [ ] Accessibility permission survives update from the previous release.
- [ ] Release notes explain that this is the first open-source release.
- [ ] Sparkle appcast is generated and attached.
- [ ] Known notarization / self-signed limitations are documented.

Community:

- [ ] Prepare a 30-60 second demo video or GIF.
- [ ] Prepare one main screenshot and one MCP screenshot.
- [ ] Prepare the HN, Reddit, V2EX, and X posts below.
- [ ] Create 8-12 starter issues with `good first issue` / `help wanted`.
- [ ] Be available for 24 hours after posting to answer questions.

## Suggested GitHub Topics

Use:

`macos`, `swift`, `swiftui`, `clipboard-manager`, `clipboard-history`, `productivity`, `local-first`, `privacy`, `semantic-search`, `mcp`, `model-context-protocol`, `ai-tools`, `menubar-app`

## Starter Issues

Good first batch:

- Add Homebrew Cask distribution.
- Add MCP resources for favorites and pinned clips.
- Add MCP prompts for clipboard summaries.
- Add tests for URL tracking-parameter stripping.
- Add tests for search token parsing.
- Document local database paths per build type.
- Add Japanese localization.
- Add German localization.
- Improve keyboard navigation in the main list.
- Add an architecture overview document.
- Profile large image capture memory usage.
- Improve first-run warning text for self-signed builds.

## Demo Script

Keep the demo short:

1. Copy a URL, a code snippet, and an image.
2. Open Clipth with `Command-Shift-V`.
3. Search with a natural-language query.
4. Show a source-app or time filter, such as `app:Safari since:2d`.
5. Open MCP settings and show the config snippet.
6. In an MCP client, ask: "Find the release-signing clip I copied recently."
7. End on the privacy point: local database, offline embeddings, no telemetry.

## Launch Copy

### Hacker News

Title:

```text
Show HN: Clipth, a local-first clipboard manager for macOS with MCP search
```

First comment:

```text
Hi HN, I built Clipth, an open-source macOS clipboard manager focused on local-first search and AI-tool workflows.

The angle is not "yet another clipboard history app." I wanted a local clipboard memory that Claude Desktop, Claude Code, Cursor, and other MCP clients could query without sending clipboard contents to a hosted service.

The app is SwiftUI + SwiftData. Semantic search uses Apple's on-device NLEmbedding. The same binary can run as an MCP stdio server with tools for search, recent history, tags, favorites, pins, delete/restore, and snippet creation.

Privacy boundaries are documented here:
https://github.com/wavever/Clipth/blob/main/PRIVACY.md

I would especially appreciate feedback on the MCP interface, privacy model, and macOS release/signing experience.
```

### Reddit / r/macapps

```text
[Open Source] Clipth - local-first clipboard history for macOS with offline semantic search and MCP

I open-sourced Clipth, a native macOS clipboard manager built with SwiftUI.

Main points:
- local clipboard history
- offline semantic search using Apple NLEmbedding
- OCR indexing for images
- tags, pins, snippets, trash, stats
- built-in MCP stdio server for Claude Desktop / Claude Code / Cursor
- no analytics, no telemetry, no cloud sync

Repo:
https://github.com/wavever/Clipth

I am looking for feedback on the install experience, privacy model, and which MCP tools should come next.
```

### V2EX

```text
我把自己做的 macOS 剪贴板历史工具 Clipth 开源了。

它不是想做「又一个剪贴板管理器」，主要差异是：

- 本地优先，数据保存在本机
- 基于 Apple NLEmbedding 的离线语义搜索
- 图片 OCR 入索引
- 内置 MCP stdio server，可以让 Claude Desktop / Claude Code / Cursor 查询本地剪贴板历史
- 无分析、无遥测、无云同步

仓库：
https://github.com/wavever/Clipth

希望听听大家对隐私边界、安装体验、MCP 工具设计的反馈。
```

### X / Threads

```text
I open-sourced Clipth, a local-first clipboard history app for macOS.

It has offline semantic search and a built-in MCP server, so Claude Desktop / Claude Code / Cursor can search clipboard history without uploading it to the cloud.

GitHub: https://github.com/wavever/Clipth
```

## Launch Order

Recommended order:

1. GitHub Release and README polish.
2. Personal social post.
3. V2EX / Chinese dev communities.
4. Reddit `r/macapps`.
5. Hacker News Show HN.
6. Awesome lists and MCP directories.
7. Product Hunt only after the install experience is smoother, ideally with notarization or clearer Gatekeeper instructions.

Avoid posting everywhere at once. Each launch wave should produce feedback that can be folded into the next patch release.
