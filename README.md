<p align="center">
  <img src="ClipTrace/Assets.xcassets/AppLogo.imageset/AppLogo@2x.png" width="96" alt="ClipTrace logo" />
</p>

<h1 align="center">ClipTrace</h1>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  Local-first clipboard history for macOS and AI tools.
</p>

<p align="center">
  <a href="https://wavever.github.io/ClipTrace/"><img src="https://img.shields.io/badge/website-cliptrace-7AA487" alt="Website" /></a>
  <a href="https://github.com/wavever/ClipTrace/actions/workflows/ci.yml"><img src="https://github.com/wavever/ClipTrace/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/wavever/ClipTrace/releases/latest"><img src="https://img.shields.io/github/v/release/wavever/ClipTrace" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+" />
</p>

ClipTrace is an open-source macOS clipboard manager with offline semantic search and a built-in [Model Context Protocol](https://modelcontextprotocol.io/) server. It lets you search clipboard history locally, organize useful clips, and optionally let AI clients such as Claude Desktop, Claude Code, or Cursor query your clipboard without uploading it to a cloud service.

## Why ClipTrace?

- **Local-first by default** - clipboard history, OCR text, tags, and embeddings stay on your Mac.
- **Offline semantic search** - Apple `NLEmbedding` powers meaning-based search without hosted embedding APIs.
- **AI-native workflow** - the app binary can run as an MCP stdio server with searchable and writable clipboard tools.
- **Native macOS utility** - menu bar app, global hotkeys, Quick Paste, previews, snippets, and SwiftUI interface.
- **Content protection** - sensitive values such as phone numbers and API keys are redacted across the UI, exports, and MCP by default, while the original stays on your Mac for reuse.
- **Privacy controls** - pause capture, exclude source apps, ignore sensitive pasteboard markers, strip URL trackers, disable MCP tools, and delete history.

## Preview

<p align="center">
  <img src="docs/assets/screenshot-main.png" alt="Main window" width="720" />
  <br/>
  <em>Main window - history, full-text and semantic search, tags</em>
</p>

<p align="center">
  <img src="docs/assets/screenshot-stats.png" alt="Activity stats" width="720" />
  <br/>
  <em>Activity stats - daily count and yearly heatmap</em>
</p>

<p align="center">
  <img src="docs/assets/screenshot-mcp.png" alt="MCP integration" width="720" />
  <br/>
  <em>MCP server - connect Claude Desktop, Claude Code, or Cursor</em>
</p>

## Features

### Capture and Reuse

- Auto-captures text, images, video, files, URLs, and rich text
- Double-click to copy an entry back to the clipboard
- Duplicate refresh keeps re-copied items at the top instead of creating duplicates
- Optional paste-as-plain-text and trailing-whitespace trimming
- Soft-delete trash with restore, permanent delete, and retention controls
- Global hotkeys for the main window and snippets
- Efficient image storage — clipboard images are kept compressed with external binary storage, so memory and disk usage stay low even with a long image history
- Switch between list and grid layouts: the main window uses a responsive grid, while Quick Paste and the menu bar panel offer independently configurable two-column grids in Settings. Grid image previews preserve their aspect ratio and show the image name as an in-place overlay.

### Search and Organization

- Full-text search with type filters
- Offline semantic search over text and OCR content
- Source-app and time filters such as `app:Safari`, `since:2d`, and `before:2026-05-01`
- Favorites, pinned clips, tags, custom titles, and tag autocomplete
- Multi-select merge for clips of the same type

### Content Awareness

- Rich preview popover
- OCR indexing for images
- Smart text parsing for timestamps, Base64, and JSON
- Video preview with thumbnail or inline player mode
- URL tracking-parameter stripping for `utm_*`, `fbclid`, `gclid`, and more
- Screen-recording hide mode for the app window

### Content Protection

- Automatic, conservative redaction of sensitive spans: Chinese mainland phone numbers (`13812345678` → `138****5678`) and API keys, tokens, secrets, and passwords — labeled values such as `appkey=…` plus high-confidence prefixes like `sk-`, `ghp_`, `AKIA`
- Masks only the sensitive value while keeping surrounding labels and structure; conservative enough to leave UUIDs, hashes, timestamps, and ordinary URLs untouched
- Redacted display across the history list, previews, menu bar, Dynamic Island, Quick Paste, Quick Look, and search snippets, with a lock badge on protected clips
- The original value is never modified in storage — copy, quick paste, paste-as-plain-text, and edits still use the raw clip
- Default exports and MCP responses return redacted content with `isProtected` metadata; raw egress requires an explicit opt-in
- Master switch and one editable rule list in Settings → Privacy: the built-in phone/app-key rules can be edited, reset, or turned off, alongside your own keyword or regex rules

### Export and Stats

- JSON export with type, date, favorite, and pinned filters
- Per-item export to original formats such as text and PNG
- Copy statistics, 14-day chart, and GitHub-style yearly heatmap

## MCP Server

The app binary doubles as an MCP stdio server. Configure a compatible client with:

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

Available tools:

| Tool | Description |
|---|---|
| `search_clipboard` | Keyword or semantic search over clipboard history |
| `list_recent` | List recent entries, optionally filtered by type |
| `get_clip` | Fetch one entry by UUID with full content and metadata |
| `list_tags` | List all tags and usage counts |
| `list_recent_activity` | List entries added since an ISO date or relative time such as `30m`, `2h`, `3d`, `1w` |
| `tag_clip` / `untag_clip` | Add or remove tags |
| `favorite_clip` / `pin_clip` | Update favorite or pinned state |
| `delete_clip` / `restore_clip` | Soft-delete, permanently delete, or restore entries |
| `create_snippet` | Create a snippet with optional title and tags |

Protected clips are redacted in MCP responses by default and carry `isProtected` metadata; returning raw protected content requires an explicit opt-in in Settings → Privacy. MCP can still expose other clipboard contents to the client you configure — read [PRIVACY.md](PRIVACY.md) before enabling it for sensitive workflows.

## Install

Download the latest DMG from [GitHub Releases](https://github.com/wavever/ClipTrace/releases/latest), open it, and drag ClipTrace into Applications.

Current public releases are signed with a stable self-signed identity so macOS can keep Accessibility permission across updates. Public notarization is on the roadmap. If macOS blocks a downloaded build, you can build from source with unsigned local signing disabled.

## System Requirements

- macOS 14.0 Sonoma or later
- Xcode 16.0 or later recommended for development

## Build from Source

Open `ClipTrace.xcodeproj` in Xcode, select "My Mac", and run.

Command line:

```bash
xcodebuild \
  -project ClipTrace.xcodeproj \
  -scheme ClipTrace \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Code Signing for Maintainers

Releases use a stable self-signed certificate so macOS keeps Accessibility permission across rebuilds and updates. Without a stable signing identity, the permission can be invalidated after each build even if the System Settings toggle still appears enabled.

Run once to create and install the certificate:

```bash
scripts/generate-signing-cert.sh
```

The script prints `SIGNING_CERT_P12_BASE64` and `SIGNING_CERT_PASSWORD` values for GitHub Actions secrets.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘⇧V` | Open main window |
| `⌘,` | Open settings |
| `⌘N` | New snippet |
| `⌘⏎` | Save in snippet editor |
| `Esc` | Dismiss preview, go back, or cancel edit |

## Project Docs

- [Privacy](PRIVACY.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Roadmap](ROADMAP.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Contributing

Issues and pull requests are welcome. Good first areas include documentation, localization, MCP resources/prompts, URL sanitizer tests, search parser tests, and privacy polish.

Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md). For private security or privacy reports, follow [SECURITY.md](SECURITY.md).

## License

ClipTrace is released under the [MIT License](LICENSE).
