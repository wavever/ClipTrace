## Context

ClipTrace is a local-first, privacy-first macOS clipboard manager. The capture path already contains a small rule engine: `ClipboardMonitor.checkForChanges()` (main-thread `Timer`, 0.5s) filters sensitive/internal/dedup cases, then hands a new clip to `ClipboardViewModel`'s `onNewContent` closure, which runs `FilterSettingsStore.shouldExclude(type:content:sourceBundleId:)` and either drops the clip or inserts a `ClipboardItem` and kicks off asynchronous OCR/embedding backfill in a detached `Task`.

This change generalizes that matcher from "match → exclude" into "match → action," where an action may run user-authored code. Constraints that shape the design:

- **Non-sandboxed app.** The main target ships with `CODE_SIGN_ENTITLEMENTS = ""` (only the widget is sandboxed). `Process` and `JavaScriptCore` are therefore usable without new entitlements, and the self-signed / no-hardened-runtime signing flow must not gain any entitlement/provisioning requirement.
- **SwiftData is `@MainActor`.** Inserts and mutations happen on the main actor; the capture closure runs on the main thread. Anything slow must move off-main and write back on-main.
- **Sensitive content is already shielded.** Concealed/transient/sensitive pasteboard types are filtered in `ClipboardMonitor` *before* the capture callback, so downstream consumers (including scripts) structurally never see them.
- **xcodeproj uses explicit file refs.** New `.swift` files require `project.pbxproj` edits; prefer extending existing target files.
- **UI must use the paper design system tokens** and the established interpolating-spring motion.

## Goals / Non-Goals

**Goals:**
- Turn the existing exclude-only filter into a general rule engine: conditions (type, content regex, source app, length) → one action.
- Two script backends — external `.sh` (via `Process`) and inline JS (via `JavaScriptCore`) — behind one unified Effect output contract that reuses existing view-model verbs.
- Same rule fires automatically on capture and is invokable manually from a clip's context menu.
- Script execution never blocks capture or UI; failures are contained, time-bounded, and surfaced.
- Privacy posture is the default: JS has no network/filesystem access unless explicitly granted; concealed clips never reach scripts.

**Non-Goals:**
- No npm/package ecosystem, no module system for JS, no bundled Python/Lua interpreter.
- No OS-level sandboxing of shell scripts (the app is non-sandboxed; guardrails are application-level and best-effort).
- No script marketplace/sharing, import/export, or remote fetch of scripts in this change.
- No change to the concealed-type filter itself or to OCR/embedding behavior.
- No synchronous, pre-insert *script* execution (only the code-free regex `drop` tier may run pre-insert).

## Decisions

### Decision 1: Generalize the existing matcher rather than build a parallel engine
The current `TextFilterRule` (mode `contains`/`excludes` + text) and `shouldExclude` become the seed of the rule model. `contains`/`excludes` generalize to a regex condition; "exclude" becomes the `drop` Effect — one action among several.
- **Why:** The capture pipeline already calls a matcher at exactly the right point; reusing it keeps one evaluation site, one persistence blob, and preserves today's behavior as a special case. Less surface, no duplicated matching logic.
- **Alternative considered:** A separate "automations" subsystem parallel to filters. Rejected — two matchers racing on the same capture event invites ordering bugs and double-evaluation, and splits a concept users perceive as one ("rules about my clips").
- **Migration note:** Existing `textFilters` / `excludedApps` / `excludedTypes` must keep working; either map them into the new rule model on load, or keep them as the pre-insert tier and layer rules on top. Lightweight, no data loss.

### Decision 2: Scripts run asynchronously, post-insert (mirror OCR/embedding backfill)
The clip is inserted immediately; a detached `Task` runs the script off-main, then writes the Effect back on the main actor — exactly how `ocrText`/`embedding` are backfilled today.
- **Why:** The capture closure is on the main thread with `@MainActor` SwiftData. Synchronous `Process`/JS there would freeze the UI and stall the 0.5s monitor. Post-insert async guarantees "copy is instant, enrichment follows," which the app already does and users already accept (OCR text appears a beat later).
- **Trade-off:** A `drop` requested by a *script* can't prevent insertion — it must soft-delete the already-stored clip (a brief flash-in/flash-out). Accepted. Only the code-free regex `drop` tier runs pre-insert to preserve today's clean exclusion.
- **Alternative considered:** Synchronous pre-insert execution with a hard timeout. Rejected — even a 100ms script tax on every copy is a perceptible regression, and a hung process would wedge clipboard monitoring.

### Decision 3: Two backends, one Effect contract
`ScriptEffect` enum: `replaceText(String) | newClip(String) | setTags([String]) | rename(String) | copyToPasteboard(String) | drop | none`. Shell maps stdout/exit-code (and optional stdout-JSON) to it; JS maps its return value to it. The engine applies a `ScriptEffect` by calling existing VM verbs (`rename`, `setTags`, `copyToClipboard`, content update, `context.insert`, soft-delete).
- **Why:** One application path regardless of backend; new Effect kinds extend in one place; each Effect already has a proven VM verb behind it.
- **Loop-safety:** Effects that touch the pasteboard must route through `ClipboardMonitor.markInternalWrite()` so they don't re-enter capture and re-trigger rules.
- **Alternative considered:** Let each backend mutate the model directly. Rejected — scatters persistence/main-actor handling and makes loop-safety and auditing impossible to centralize.

### Decision 4: JavaScriptCore is the safe default; shell is the power tier
JS runs in a bare `JSContext` with only a `clip` object injected — no `fetch`, no `require`, no filesystem. Host capabilities are opt-in per rule. Shell gets the full CLI ecosystem via `Process` but no OS sandbox.
- **Why:** JS-default makes privacy the default state, not a bolt-on, and needs no new entitlements. Shell is offered because "pipe my clip to `jq`/`pandoc`" is a real, explicitly-requested use case that JS can't serve.
- **Alternative considered:** Shell-only (simpler, instantly powerful) — rejected as the default because auto-running arbitrary shell on every clipboard event in a non-sandboxed app holding sensitive data is the worst-case posture. JS-only — rejected because it abandons the user's stated CLI-piping use case.

### Decision 5: Application-level safety rails (no OS backstop)
Per-run timeout with termination (`Process.terminate()` / JSC execution-time interruption), error routing through the existing `ToastCenter`, a bounded recent-run log, a managed `~/Library/Application Support/ClipTrace/Scripts/` directory for `.sh` files, and an explicit enable-time authorization gate (reuse `ConfirmationCenter`) before any script rule arms.
- **Why:** Because the app is non-sandboxed, these are the only guardrails. The authorization gate ensures a user consciously accepts "this runs code on my clipboard." The run log makes script behavior auditable instead of invisible magic.
- **Trade-off:** Guardrails are best-effort — a determined shell script can ignore them. Documented as a non-goal to "sandbox" shell.

### Decision 6: Threading / actor model
Matching is cheap and stays on the main actor in the capture closure. Script execution runs off the main actor (`Process` on a background queue; JS in a `JSContext` evaluated on a background thread/queue with an interrupt watchdog). The resulting `ScriptEffect` is hopped back to `@MainActor` to mutate SwiftData and save — identical to the OCR backfill's `Task { @MainActor in ... }` write-back.

### Decision 7: Persistence and file layout
Rules serialize as Codable alongside the existing `filterSettings.v1` UserDefaults state (or a sibling `scriptingRules.v1` key) via `FilterSettingsStore`. New Swift types (rule model, match evaluator, Effect, shell runner, JS runner, run-log) are added to existing target files where reasonable to minimize `project.pbxproj` churn; any unavoidable new file gets a matching pbxproj entry as an explicit task.

```
 capture (main thread)
   │  ClipboardMonitor.checkForChanges()  ── concealed/internal/dedup filters ──▶ skip
   ▼
 onNewContent closure (ClipboardViewModel, main actor)
   │  ① pre-insert tier: code-free regex rules with action=drop ──▶ exclude (never stored)
   │  ② insert ClipboardItem + save  (clip is now visible)
   ▼
 Task.detached  ── off-main ──────────────────────────────────────────────┐
   │  for each enabled matching rule (in order):                          │
   │     run shell(Process) | js(JSContext)   ⏱ timeout+cancel            │
   │     map result ──▶ ScriptEffect                                      │
   ▼                                                                      │
 Task { @MainActor }  ── apply ScriptEffect via existing VM verbs ◀───────┘
        replaceText / setTags / rename / newClip / copyToPasteboard / drop
        (pasteboard writes guarded by markInternalWrite to avoid loops)
        → log run, toast on error
```

## Risks / Trade-offs

- **Auto-running shell on captured clipboard = exfiltration surface** → Mitigations: concealed clips never reach scripts (structural); JS default-deny is the recommended path; explicit enable-time authorization gate; managed scripts dir; run log; documentation framing shell as the user-owned power tier.
- **Hung/slow script wedges capture** → Mitigation: async post-insert + per-run timeout + termination; capture never awaits a script.
- **Effect re-triggers capture (infinite loop)** → Mitigation: all pasteboard-touching Effects route through `markInternalWrite()`; applying an Effect is never counted as a user copy.
- **Script `drop` causes flash-in/flash-out** → Accepted; only the code-free regex tier drops pre-insert. Could be smoothed later by deferring the Dynamic Island flash for clips with pending script rules.
- **Regex evaluated on every clip = CPU** → Mitigation: regexes are precompiled and cached; conditions short-circuit (type/length checked before regex); evaluation only runs on clips that already passed dedup/sensitive filters.
- **JSC execution-time interruption API is C-level/legacy** → Risk that interruption is coarse; Mitigation: run JS on a dedicated background thread that can be abandoned, with the watchdog as the cancellation signal; validate during the runner spike.
- **pbxproj drift from new files** → Mitigation: prefer extending existing target files; treat any new `.swift` as an explicit pbxproj task and build to verify.
- **Signing flow regression** → Mitigation: use only `Process` + `JavaScriptCore` (system framework); add no entitlements; verify a self-signed build still runs and retains accessibility grant.

## Migration Plan

1. Introduce the rule model and Effect types without wiring them into capture; keep `shouldExclude` authoritative (no behavior change).
2. On load, fold existing `textFilters`/`excludedApps`/`excludedTypes` into the rule list (or retain as the pre-insert tier) so current users see their filters preserved.
3. Wire automatic evaluation into the post-insert `Task`; ship with no script backends enabled by default (rules list empty → byte-for-byte today's behavior).
4. Add backends behind the authorization gate, then the Settings management UI and the context-menu manual invocation.
- **Rollback:** Feature is additive and gated; an empty rule list reproduces current behavior. Disabling the feature flag / removing rules fully reverts runtime behavior.

## Open Questions

- Should existing `textFilters`/`excludedApps`/`excludedTypes` be migrated into unified rules, or kept as a distinct always-on pre-insert tier with rules layered above? (Leaning: keep them as the pre-insert tier for v1 to avoid migration risk.)
- Shell stdout protocol for rich Effects: a documented JSON envelope vs. plain-text-only (string → `replaceText`) for v1? (Leaning: plain text first; JSON envelope as a documented opt-in.)
- Which host capabilities (if any) are exposable to JS in v1 beyond pure computation — e.g. a gated `http.get`? (Leaning: none in v1; pure compute only, capability framework stubbed for later.)
- Default timeout value and whether it is per-rule configurable. (Leaning: ~3s global default, per-rule override later.)
