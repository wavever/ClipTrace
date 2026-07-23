## Product Decisions

### Preserve Utility, Reduce Ambient Exposure

The feature must not turn sensitive clips into unusable clips. Clipth should
continue to store the raw value locally and use it for explicit copy/paste
actions. The protection layer applies when content is being observed or leaving
the app by default.

The user-facing model is:

- "I can still reuse the original clip."
- "Clipth will not casually show the original value on screen."
- "Bulk export and MCP will not leak protected raw values unless I explicitly
  allow that."

### Default State

Content Protection should be enabled by default for built-in detectors. This is
consistent with Clipth's privacy positioning and avoids a feature that only
works after the first accidental exposure.

Settings should still allow users to disable the whole feature or individual
categories when a detector is too noisy for their workflow.

## Detection Model

Add a small pure service, for example `ContentProtector`, that accepts a text
string and returns:

- `redactedText`
- `isProtected`
- matched categories
- sensitive ranges, if useful for UI badges/tooltips or tests

The service should be independent of SwiftUI and SwiftData so it can be tested
directly and reused by export/MCP code.

### Phone Numbers

The v1 detector should prioritize Chinese mainland mobile numbers:

- optional `+86`/`86` prefix;
- `1[3-9]` mobile prefix;
- 11 digits total, allowing spaces or dashes between groups;
- digit boundaries to avoid matching inside longer numbers.

International/E.164-style numbers should be matched only when nearby context
suggests a phone number, such as `phone`, `mobile`, `tel`, `contact`, `手机号`,
or `电话`. This avoids masking arbitrary long IDs.

Masking policy:

- keep the first 3 and last 4 digits for CN mobile numbers;
- preserve the visible country prefix if present;
- normalize the masked core as `138****5678` rather than preserving every
  original separator.

### App Keys, Tokens, and Secrets

The v1 detector should cover:

- key-value labels such as `appkey`, `app_key`, `api_key`, `apikey`,
  `access_key`, `access-token`, `token`, `secret`, `client_secret`,
  `password`, `passwd`, `authorization`, and `bearer`;
- common token prefixes such as `sk-`, `ghp_`, `github_pat_`, `xoxb-`,
  `xoxp-`, `AKIA`, and similar high-confidence provider prefixes;
- quoted JSON, `.env`, URL query, and plain `key=value` shapes.

For generic high-entropy strings, require either a sensitive label nearby or a
high-confidence prefix. Do not blindly mask UUIDs, commit SHAs, hashes,
timestamps, order numbers, or ordinary URLs without a sensitive key name.

Masking policy:

- mask only the secret value, preserving labels, delimiters, quotes, and URL
  structure;
- for values with length 8 or more, keep the first 4 and last 4 visible
  characters;
- for values shorter than 8, keep at most the first and last character;
- use a bounded middle marker of 4 to 12 `*` characters rather than exposing the
  exact hidden length.

The redactor must be idempotent: re-running it on already-redacted output should
not create progressively longer masks.

## Presentation Boundaries

Every text-rendering surface should ask for protected display text instead of
reading `item.content` directly when the content may be visible to a user or
captured by screenshots:

- main history rows and detail/preview popovers;
- menu bar and Dynamic Island surfaces;
- Quick Paste;
- copy feedback/toasts;
- widget snapshots;
- Quick Look materialized text/RTF files;
- search snippets and highlighted previews;
- OCR text display.

Search may continue indexing and matching the raw stored content so users can
find clips they need. Result rows and snippets must still render the protected
string.

Tags, custom titles, source app names, item types, and timestamps are not
redacted by this feature.

## Raw Content Reuse

The existing reuse actions continue to operate on raw content:

- copy item;
- paste/quick paste;
- copy as plain text;
- manual edit/save flows.

Those actions are explicit user intent and are the reason the raw clip is kept.
The UI should not reveal the raw value as part of performing the action.

## Export and MCP Guardrails

Bulk export and MCP tools are egress surfaces, not just display surfaces.

Defaults:

- exported JSON/text for protected clips uses the redacted value and includes a
  flag such as `isProtected: true` plus categories if already available;
- MCP `list_recent`, `search_clipboard`, and `get_clip` return redacted content
  for protected clips by default, with equivalent protected metadata;
- raw protected export or MCP access requires an explicit user setting and, for
  one-off UI export flows, a confirmation step.

This can be relaxed later, but v1 should bias toward non-leakage.

## Non-Text Content

V1 does not attempt pixel-level redaction in images, videos, PDFs, or arbitrary
files. If OCR text exists for an image, that OCR text must be redacted anywhere
it is displayed, searched as a snippet, exported as text, or returned through
MCP. The original image/file thumbnail and raw binary export are unchanged.

## Relationship to Clipboard Rules

The existing rule/script engine is user-authorized automation. Content
Protection should not silently block authorized rules from receiving raw content,
because many rules exist to transform or tag the original value. The existing
concealed/transient pasteboard filter remains the hard privacy boundary before
any storage or scripting.

Settings copy should make the distinction clear: Content Protection hides
sensitive values in Clipth surfaces and guarded egress paths; it is not a
secret manager or a sandbox for user-authored scripts.
