## Why

ClipTrace already matches every captured clip against user rules (`FilterSettingsStore.shouldExclude`), but the only action it can take is "drop it." Power users (the CopyQ / Pastebot / Keyboard Maestro crowd) want to *do* things to clips — pretty-print JSON, strip noise, auto-tag secrets, pipe to their own CLI tools — and today the only programmable surface is the LLM-facing MCP server, which can't run on capture. Generalizing the existing matcher from "match → exclude" into "match → run a script" turns a one-trick filter into a user-programmable automation engine, without touching the privacy invariants that already protect sensitive content.

## What Changes

- Generalize the capture-time matcher into a **rule engine**: each rule = a set of match conditions + an action. Match conditions extend today's filter (clip type, source app) with **regex on content** and **length bounds**.
- Add two **script action backends**:
  - **Shell**: run an external `.sh` file. Clip text on `stdin`, metadata in env vars, image as a temp-file path; `stdout` is the result, exit code signals success/skip.
  - **JavaScript**: run inline JS in a sandboxed `JavaScriptCore` context with an injected `clip` object; the return value is the result. No network/filesystem access by default.
- Both backends collapse their output into one **Effect** model — `replaceText | newClip | setTags | rename | copyToPasteboard | drop | none` — each mapping onto an existing `ClipboardViewModel` verb.
- **Two triggering modes for the same rule**: automatically on capture, and manually via the clip row's right-click menu.
- **Async post-capture execution**: scripts run in a detached `Task` after the clip is already stored (mirroring the existing OCR/embedding backfill), so a slow or hung script can never block clipboard monitoring or the UI. The lightweight regex-only `drop`/`replaceText` tier may still run synchronously before insert.
- **Settings UI** for creating, ordering, enabling, and testing rules, plus an authorization gate before any script-running rule can be enabled and a recent-run log for auditability.
- Safety rails the OS won't provide (the app is non-sandboxed): per-run timeout + cancellation, error surfacing through the existing toast layer, and a managed scripts directory.

## Capabilities

### New Capabilities

- `clipboard-rules`: The rule model and engine — match conditions (type, content regex, source app, length), rule storage/ordering/enablement, the two trigger modes (auto-on-capture and manual), and how a produced Effect is applied to a clip by reusing existing view-model verbs. Generalizes the current exclude-only filter into a match→action pipeline.
- `clipboard-scripting`: The script execution runtime that fulfills a rule's action — the shell (`stdin`/env/`stdout`/exit-code) and JavaScript (`JSContext` + injected `clip` API) backends, the unified Effect output contract, and the application-level security model (default-deny capabilities for JS, per-run timeout/cancellation, the sensitive-content invariant, managed scripts directory, and the enable-time authorization gate).

### Modified Capabilities

<!-- None. No prior specs exist in openspec/specs/; the existing exclude-filter behavior is code-only and is generalized here rather than re-specified. -->

## Impact

- **Code (modify)**: `ClipboardViewModel.swift` (capture `onNewContent` closure + post-insert `Task` becomes the rule-engine hook); `FilterSettings.swift` / `FilterSettingsStore` (generalize `TextFilterRule` and `shouldExclude` into the rule model + sync pre-insert tier); `ClipboardItemRow.swift` (manual "run rule" entries in the context menu, following the existing OCR/QR sheet pattern); `SettingsPanelView.swift` (rule management panel).
- **Code (new types)**: rule model, match evaluator, Effect model, shell runner, JS runner, run-log. Per project convention (explicit pbxproj file refs), prefer adding these to existing target files; any genuinely new `.swift` file requires a `project.pbxproj` edit.
- **Invariant preserved**: concealed/transient/sensitive clips are filtered in `ClipboardMonitor.checkForChanges` *before* the capture callback, so scripts structurally never see them — no new sensitive-data handling needed, but the invariant must be documented and protected.
- **Runtime/permissions**: introduces in-process JS evaluation (`JavaScriptCore`, system framework) and external process execution (`Process`) — both available without new entitlements, so the self-signed / no-hardened-runtime signing flow is unaffected. No new dependencies.
- **Persistence**: rules and their settings serialize alongside the existing `filterSettings.v1` UserDefaults blob (or a sibling key); user `.sh` files live under `~/Library/Application Support/ClipTrace/Scripts/`.
- **UI/UX**: all new controls use the paper design-system tokens; any panel transitions follow the established interpolating-spring motion.
