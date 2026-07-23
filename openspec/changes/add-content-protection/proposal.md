## Why

Clipth is local-first, but it still renders clipboard text verbatim across
ambient surfaces: the main history list, menu bar, Dynamic Island copy feedback,
Quick Paste, previews, exports, widgets, and MCP tools. When users copy values
such as app keys, API tokens, passwords, or phone numbers, keeping the clip is
useful, while showing the raw value in every surface is unnecessarily risky.

Dropping these clips would destroy the core clipboard-manager workflow. The
better product behavior is to keep the original value available for explicit
reuse, but redact sensitive spans whenever Clipth displays, previews, exports
by default, or exposes clipboard text to AI clients.

## What Changes

- Add a **Content Protection** layer that detects sensitive spans in text-like
  clipboard content and produces a redacted display string without mutating the
  stored clip.
- Enable built-in conservative detectors for:
  - phone numbers, with CN mobile numbers as the primary v1 case and
    international/E.164-style numbers only when phone context is present;
  - app keys, API keys, access tokens, bearer tokens, client secrets, passwords,
    and common provider token prefixes.
- Mask only the sensitive value, not surrounding labels or syntax. Examples:
  `13812345678` becomes `138****5678`; `appkey=abcdef1234567890` becomes
  `appkey=abcd********7890`.
- Apply redaction at presentation boundaries: main rows, menu bar/Dynamic
  Island rows, Quick Paste, preview popovers, text/RTF Quick Look materialization,
  copy toasts, widget snapshots, search snippets, export defaults, and MCP text
  responses.
- Preserve raw content for explicit reuse actions: copy, quick paste, paste as
  plain text, and local editing operations continue to operate on the stored raw
  clip.
- Add privacy settings: a master Content Protection toggle, per-category
  detector toggles, visible protected-state affordances, and explicit opt-ins
  before raw protected content can leave the app through export or MCP.
- Keep non-text media pixel redaction out of scope for v1. OCR text derived from
  images must be redacted anywhere it is displayed or returned, but the original
  image thumbnail/file is not modified.

## Capabilities

### New Capabilities

- `content-protection`: Sensitive-span detection, masking policy, presentation
  boundaries, raw-content reuse rules, settings, and export/MCP guardrails.

### Modified Capabilities

- `clipboard-rules`: Rule/script execution may still receive raw clips after
  the existing concealed/transient pasteboard filter. Content Protection is a
  display and egress guard, not a replacement for the existing script
  authorization gate.

## Impact

- **Code (new or modified):** a detector/masker service, settings persistence
  model, localization entries, and protected-display helpers on `ClipboardItem`
  or the view model.
- **UI surfaces:** `ClipboardItemRow`, `MenuBarView`, `QuickPasteView`,
  `PreviewPopover`, `QuickLookCoordinator`, `DynamicIslandView`/copy feedback,
  widget snapshot generation, and settings.
- **Data/egress surfaces:** `ExportService`, `MCPServer`, search result/snippet
  rendering, and any text/RTF materialization path.
- **Persistence invariant:** stored clipboard content remains raw and unchanged;
  redaction is computed for display/egress unless the user explicitly opts into
  raw protected output.
- **Testing:** pure detector/masker tests plus integration checks for display
  masking, raw copy behavior, export/MCP defaults, and false-positive cases.
