# Agent brand icons

`Clipth/Assets.xcassets/Agent*.imageset` holds the brand marks shown in
Settings → AI → 一键接入 AI 客户端. Most of the agents we support are CLIs with no
app bundle to borrow an icon from, so each mark is checked in at 32/64/96 px
(1x/2x/3x).

The row prefers the **installed app's own icon** when the client ships one
(Cursor, Zed, LM Studio …) — that is by definition what the user sees in the
Dock. These assets are the fallback, and the only option for CLI agents.

## Where each one came from

| Asset | Source | Notes |
|---|---|---|
| `AgentClaudeCode` | `anthropic.claude-code` VS Code extension icon | Anthropic's own publisher artwork |
| `AgentClaudeDesktop` | lobe-icons `claude-color` | The Claude starburst |
| `AgentCodex` | lobe-icons `codex-color` | **Not** the ChatGPT app icon — see below |
| `AgentCline` | `saoudrizwan.claude-dev` VS Code extension icon | Publisher's own artwork |
| `AgentAmazonQ` | `aws/aws-toolkit-vscode` → `icons/aws/amazonq/q-gradient.svg` | AWS's own artwork |
| `AgentVSCode` | `code.visualstudio.com/apple-touch-icon.png` | The branded icon; the icon in the `microsoft/vscode` repo is the **Code - OSS** build's |
| `AgentZed` | `zed-industries/zed` → `crates/zed/resources/app-icon@2x.png` | |
| `AgentOpenCode` | `opencode.ai/favicon.svg` | |
| `AgentOpenClaw` | lobe-icons `openclaw-color` | Verified identical to the lobster favicon shipped in the `openclaw` npm package |
| `AgentGeminiCLI`, `AgentQwenCode`, `AgentKiro` | lobe-icons `*-color` | |
| `AgentCursor`, `AgentWindsurf`, `AgentLMStudio` | lobe-icons monochrome | Stored as **template** art and tinted with the brand color, so they stay legible in dark mode |

Trademarks belong to their respective owners; the marks are used only to
identify each product in a connect-to-this-client list.

## Regenerating

SVG sources rasterize with `rsvg-convert -w <px> -h <px> in.svg -o out.png`;
PNG/ICNS sources with `sips -s format png -z <px> <px>`. A monochrome mark needs
`"template-rendering-intent": "template"` in its `Contents.json` so
`foregroundStyle` can tint it.

## Bundle-id caveat

`com.openai.codex` is registered by **ChatGPT.app**, so looking the Codex CLI up
by bundle id yields the ChatGPT icon. That bundle id is deliberately absent from
the Codex target's `bundleIDs`; detection relies on `~/.codex` and the `codex`
binary instead.
