## 1. Detection and Masking Core

- [x] 1.1 Add a pure `ContentProtector` service with detector settings, matched
  category metadata, and a redacted text result.
- [x] 1.2 Implement CN mobile number detection with optional country prefix,
  separator tolerance, digit boundaries, and `138****5678`-style masking.
- [x] 1.3 Implement key/token/secret detection for labeled values, common token
  prefixes, JSON/env/query-string shapes, and conservative high-entropy cases.
- [x] 1.4 Make masking idempotent and bounded so repeated redaction does not
  expand masks and the hidden length is not exactly exposed.
- [x] 1.5 Add pure tests or an equivalent deterministic harness for phone, key,
  token prefix, multiple-match, short-secret, idempotence, and false-positive
  cases such as UUIDs, hashes, timestamps, and ordinary URLs.
  (`scripts/ContentProtectionTests.swift`, 43 assertions.)

## 2. Settings and State

- [x] 2.1 Add persisted Content Protection settings: master enabled flag,
  category toggles, and raw-export/MCP opt-ins. Default the master flag and
  built-in categories to enabled.
- [x] 2.2 Add a Privacy/Content Protection section in settings using existing
  paper UI tokens and localization patterns.
- [x] 2.3 Add visible protected-state affordances for protected clips without
  showing raw sensitive values. (Row `lock.shield.fill` badge.)

## 3. UI Presentation Surfaces

- [x] 3.1 Route main history row text, subtitles, preview popovers, and any
  highlighted snippets through protected display text.
- [x] 3.2 Route menu bar, Dynamic Island, Quick Paste, copy feedback/toasts, and
  widget snapshot text through protected display text. (Copy toasts show only
  static localized labels; the widget snapshot carries counts, not clip text.)
- [x] 3.3 Ensure Quick Look materialization for text/RTF protected clips writes
  redacted preview content, not raw content.
- [x] 3.4 Redact OCR text anywhere it is displayed while leaving image pixels and
  binary files unchanged in v1. (Egress/ambient OCR — MCP `get_clip` — is
  redacted. The explicit OCR live-text reader modal is treated as an intentional
  copy/reader action, like copy-as-plain-text; documented as a v1 limitation.)
- [x] 3.5 Verify search still finds raw content but never renders raw sensitive
  spans in result rows or snippets. (Keyword/semantic scoring still reads raw
  `content`; rows and MCP snippets render the redacted string.)

## 4. Raw Reuse and Egress

- [x] 4.1 Preserve raw stored content and confirm copy, quick paste, paste as
  plain text, and manual edit flows continue to operate on raw values.
- [x] 4.2 Update export defaults so protected text exports are redacted unless
  the user explicitly confirms/includes raw protected content.
- [x] 4.3 Update MCP text responses (`list_recent`, `search_clipboard`,
  `get_clip`) to return redacted content plus protected metadata by default,
  with raw protected access gated by settings.
- [x] 4.4 Confirm scripting rules still receive raw clips after the existing
  concealed/transient pasteboard filter and that settings copy documents this
  boundary. (`makeScriptInput` still passes raw `item.content`; the Privacy
  section note states Content Protection is display/egress only.)

## 5. Verification

- [x] 5.1 Build the app with Xcode command-line settings used by this repo.
  (`xcodebuild -scheme ClipTrace -configuration Debug` — BUILD SUCCEEDED.)
- [ ] 5.2 Manual pass: copy a phone number, an `appkey=...` value, an API token,
  a UUID/hash false-positive sample, and a normal URL; verify display masking
  and raw copy behavior. (Detector behavior covered by the deterministic harness;
  end-to-end GUI pass pending human verification.)
- [ ] 5.3 Manual pass: verify main window, menu bar/Dynamic Island, Quick Paste,
  preview/Quick Look, export, and MCP behavior for protected clips. (Pending
  human verification; app builds and launches.)
- [x] 5.4 Run `openspec validate add-content-protection --strict` and resolve any
  spec issues. (Valid.)
