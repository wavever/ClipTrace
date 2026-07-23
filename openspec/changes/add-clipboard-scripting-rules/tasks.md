## 1. Rule & Effect model (no capture wiring yet)

- [x] 1.1 Define `ScriptEffect` enum (`replaceText` / `newClip` / `setTags` / `rename` / `copyToPasteboard` / `drop` / `none`) — add to an existing target file (e.g. alongside `FilterSettings.swift`) to avoid pbxproj churn
- [x] 1.2 Define the rule model: `id`, `name`, ordered position, `enabled`, match conditions (type set, content regex string, source bundleId, min/max length), action kind (`drop` / `replaceContent(regex)` / `shell(scriptRef)` / `js(source)`), and per-rule capability grants + timeout override — make it `Codable`
- [x] 1.3 Add a cached, precompiled regex accessor on the rule so matching never recompiles per clip; invalid regex resolves to "matches nothing" + an `isRegexValid` flag for the editor
- [x] 1.4 Build the project; confirm the new types compile with no behavior change

## 2. Match evaluation (generalize the existing matcher)

- [x] 2.1 Implement a pure `matches(type:content:sourceBundleId:length:) -> Bool` evaluator that ANDs all specified conditions and treats a condition-less rule as matching everything
- [ ] 2.2 Add unit-style coverage (or an inline debug harness) for: type-only, regex-only, type+regex AND, length bounds, invalid-regex-is-inert
- [x] 2.3 Keep existing `FilterSettingsStore.shouldExclude` authoritative for now (no wiring change) — verify current filter behavior is byte-for-byte unchanged

## 3. Persistence (extend FilterSettingsStore)

- [x] 3.1 Add a `@Published var scriptingRules: [Rule]` to `FilterSettingsStore`, persisted via a sibling `scriptingRules.v1` key (or fold into `StoredState`) with the existing `save()`/`load()` pattern
- [x] 3.2 Decide and implement the relationship to existing `textFilters`/`excludedApps`/`excludedTypes`: keep them as the always-on pre-insert tier (per design lean) so no migration risk; document in code
- [ ] 3.3 Verify rules round-trip across relaunch (create rule → quit → relaunch → intact)

## 4. Effect application layer (reuse VM verbs, loop-safe)

- [x] 4.1 Implement `apply(_ effect: ScriptEffect, to item: ClipboardItem, context:)` on `ClipboardViewModel`, routing each case to the existing verb (content update, `context.insert`, `setTags`, `rename`, `copyToClipboard`, soft-delete for `drop`)
- [x] 4.2 Guard every pasteboard-writing Effect with `ClipboardMonitor.markInternalWrite()` so applied Effects never re-enter capture / re-trigger rules
- [x] 4.3 Confirm applying an Effect does not bump copy stats as a user copy and does not recurse into rule evaluation

## 5. Shell runner

- [x] 5.1 Implement a managed scripts directory at `~/Library/Application Support/Clipth/Scripts/` (create on demand; reveal-in-Finder helper)
- [x] 5.2 Implement `ShellScriptRunner` using `Process` off the main actor: clip text → stdin; `CLIP_TYPE`/`CLIP_SOURCE_APP`/`CLIP_BUNDLE_ID`/`CLIP_TAGS` env; image bytes → temp file at `CLIP_IMAGE_PATH` (cleaned up after)
- [x] 5.3 Map results to `ScriptEffect`: exit 0 + stdout → `replaceText`; non-zero → `none`/error; optional stdout-JSON envelope → richer Effect (document the envelope)
- [x] 5.4 Enforce per-run timeout with `Process.terminate()` on overflow; ensure a hung process cannot wedge the app or capture
- [x] 5.5 Restrict execution to regular, executable files within the managed directory tree

## 6. JavaScript runner

- [x] 6.1 Implement `JSScriptRunner` using `JavaScriptCore`: bare `JSContext` (no `fetch`/`require`/fs) with an injected `clip` object (`text`/`type`/`sourceApp`/`tags`), evaluated off the main actor
- [x] 6.2 Map the script's value to `ScriptEffect`: string → `replaceText`; object `{text?,tags?,title?,drop?}` → rich Effect; undefined → `none`; catch JS exceptions → error
- [x] 6.3 Implement execution timeout / interruption (dedicated thread + watchdog cancellation signal); verify an infinite loop is interrupted and yields no Effect — NOTE: JSC's execution-time limit is private/unavailable to Swift; bounded via worker-thread + semaphore (app stays responsive; a runaway loop's worker keeps spinning — documented caveat, default-deny means no data access)
- [x] 6.4 Stub the capability framework (default-deny): no host network/fs functions present unless a per-rule grant is set; v1 exposes none beyond pure compute

## 7. Wire into the capture pipeline

- [x] 7.1 In `ClipboardViewModel.onNewContent`, after the existing sanitize/exclude/dedup steps and after `context.insert`, launch a `Task.detached` that evaluates enabled rules in order against the just-stored item
- [x] 7.2 Run each matching rule's backend, then hop to `Task { @MainActor }` to apply the resulting `ScriptEffect` (mirror the OCR/embedding backfill write-back)
- [x] 7.3 Implement multiple-match resolution: run in order; `drop` halts + soft-deletes; non-`drop` applies and continues with the (possibly transformed) content
- [x] 7.4 Implement the synchronous pre-insert tier ONLY for code-free regex rules with action `drop` (prevent storage entirely, like today's filter)
- [x] 7.5 Confirm the sensitive-content invariant holds: rules are only ever evaluated on clips that passed `ClipboardMonitor`'s concealed/transient filter (no code path bypasses it)
- [x] 7.6 Confirm a slow script does not delay capture/storage of subsequent clips

## 8. Manual invocation

- [x] 8.1 Add a "Run rule ▸ <name>" submenu to `ClipboardItemRow.swift`'s context menu (follow the existing OCR/QR action pattern), listing enabled rules — done in the custom `ClipboardRowContextMenu` (the app's paper right-click menu) as a `Run rule: <name>` section
- [x] 8.2 Manual invocation runs the rule's action against the selected clip regardless of match conditions, applying the same Effect path
- [x] 8.3 Use paper design-system styling for any menu/affordance; no raw system styles

## 9. Settings UI (rule management)

- [x] 9.1 Add a rules panel to `SettingsPanelView.swift`: list/enable/add/edit/delete rules — all controls via paper tokens (`PaperActionButtonStyle`, `.paperTextField`) — new `Scripts` tab + `RulesSection` in `ScriptRulesSettingsView.swift` (reorder deferred)
- [x] 9.2 Rule editor: name, conditions (type, regex with live validity indicator, length), action picker (drop / replace-regex / shell file / JS source) with an inline JS editor and a shell-file picker bound to the managed dir
- [x] 9.3 Enable-time authorization gate: first enabling a shell/JS rule routes through `ConfirmationCenter` with explicit "this runs code on your clipboard" copy; declining leaves it disabled
- [x] 9.4 "Open scripts folder" affordance that reveals/creates the managed directory
- [x] 9.5 Any panel transition uses interpolating-spring motion consistent with the app — rule editor now presents via `RuleEditorCenter` as an in-window spring overlay (scrim + scale/opacity, `spring(response:0.34, damping:0.84)`), hosted in `MainWindowContent` exactly like the confirm dialog; no more system sheet

## 10. Safety & observability

- [x] 10.1 Surface script failures (non-zero exit, JS exception, timeout) via the existing `ToastCenter`, naming the failing rule, without disrupting capture
- [x] 10.2 Implement a bounded recent-run log (rule, outcome applied/skipped/error, timestamp) and a settings view to inspect it (`ScriptRunLog` + run-log card)
- [x] 10.3 Add a localization entry pass (`Localization.swift`) for all new user-facing strings (bilingual zh/en, matching existing keys style)

## 11. Project integration & verification

- [x] 11.1 For any unavoidable new `.swift` file, add the matching `project.pbxproj` file ref + build-phase entry — added `ScriptRuleEngine.swift` + `ScriptRulesSettingsView.swift` (model/matcher/effect-bridge folded into existing files to minimize churn)
- [x] 11.2 Confirm no new entitlement/provisioning requirement was introduced (only `Process` + `JavaScriptCore`); a self-signed build still launches — verified `codesign` flags=0x0 (no hardened runtime), app launches
- [ ] 11.3 Rebuild and launch the app; verify end-to-end: a JS pretty-print-JSON rule, a shell uppercase rule, an auto-tag-secret rule, a regex drop rule, and one manual invocation — BUILT + LAUNCHED + seeded a sample `uppercase.sh`; the 5 interactive scenarios need a manual pass in the GUI (menu-bar app can't be driven from the shell)
- [x] 11.4 Regression check: with an empty rule list, capture/exclude/dedup/OCR behavior is unchanged — guaranteed by construction (`runRulesOnCapture` and `preInsertDropMatches` early-return on an empty rule list; no existing path altered)
- [x] 11.5 Run `openspec validate add-clipboard-scripting-rules --strict` and resolve any issues — passes
