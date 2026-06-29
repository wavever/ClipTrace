## ADDED Requirements

### Requirement: Built-in sensitive-span detection

Content Protection SHALL detect sensitive spans in text-like clipboard content
using conservative built-in detectors for phone numbers and app/API keys,
tokens, secrets, and passwords. Detection SHALL return matched categories and
the exact spans to redact without mutating the stored clipboard item.

#### Scenario: Chinese mobile number detected

- **WHEN** a text clip contains `13812345678`
- **THEN** Content Protection marks the phone number as sensitive
- **AND** the protected display string contains `138****5678`

#### Scenario: App key value detected

- **WHEN** a text clip contains `appkey=abcdef1234567890`
- **THEN** Content Protection marks only `abcdef1234567890` as sensitive
- **AND** the protected display string keeps the label and delimiter visible
- **AND** the protected display string does not contain the full original value

#### Scenario: Multiple sensitive spans detected

- **WHEN** one clip contains both a phone number and a token
- **THEN** both sensitive spans are redacted independently
- **AND** non-sensitive surrounding text remains readable

#### Scenario: Common false positives are not masked

- **WHEN** a text clip contains an unlabeled UUID, commit SHA, timestamp, order
  number, or ordinary URL without a sensitive key name
- **THEN** Content Protection does not mask that value solely because it is long
  or alphanumeric

### Requirement: Masking policy

Content Protection SHALL mask the middle of each sensitive value with `*` while
preserving enough edge context for recognition. It SHALL preserve surrounding
syntax such as labels, delimiters, quotes, JSON keys, and URL structure. Masking
SHALL be idempotent.

#### Scenario: Phone masking keeps recognizable edges

- **WHEN** a Chinese mobile number is redacted
- **THEN** the first 3 and last 4 digits remain visible
- **AND** the middle digits are replaced with `****`

#### Scenario: Secret masking keeps value edges only

- **WHEN** a detected secret value has at least 8 characters
- **THEN** the first 4 and last 4 characters of the value remain visible
- **AND** the hidden middle is replaced with a bounded run of `*`
- **AND** the exact hidden length is not exposed by the mask length

#### Scenario: Redaction is idempotent

- **WHEN** protected display text is passed through Content Protection again
- **THEN** the output is unchanged
- **AND** no additional `*` characters are added

### Requirement: Raw content is preserved for explicit reuse

Content Protection SHALL NOT overwrite, truncate, or otherwise mutate the raw
stored clipboard content. Explicit user reuse actions SHALL continue to operate
on the raw clip.

#### Scenario: Stored clip remains raw

- **WHEN** a protected text clip is stored
- **THEN** the persisted clipboard item keeps the original raw content
- **AND** protected display text is computed separately

#### Scenario: Copy action reuses raw value

- **WHEN** the user explicitly copies or quick-pastes a protected clip
- **THEN** ClipTrace writes the original raw clip content to the pasteboard
- **AND** the UI still does not reveal the raw sensitive span

### Requirement: Protected presentation surfaces

Every ClipTrace surface that displays clipboard text SHALL render protected
display text for protected clips instead of raw content. This includes main
history rows, menu bar rows, Dynamic Island content, Quick Paste, copy feedback,
preview popovers, text/RTF Quick Look materialization, widget snapshots, search
snippets, and OCR text display.

#### Scenario: Main list never shows raw sensitive text

- **WHEN** a protected clip appears in the main history list
- **THEN** the row displays the redacted value
- **AND** the raw sensitive span is not present in visible row text

#### Scenario: Search can find raw content but displays redacted snippets

- **WHEN** the user searches for text that exists only in the raw sensitive span
- **THEN** the matching clip can still be found
- **AND** the rendered result row and snippet show protected display text

#### Scenario: Quick Look text preview is redacted

- **WHEN** the user opens Quick Look for a protected text or RTF clip
- **THEN** the materialized preview file contains redacted content
- **AND** it does not contain the raw sensitive span

#### Scenario: OCR text is redacted but image pixels are unchanged

- **WHEN** an image clip has OCR text containing a sensitive value
- **THEN** displayed/exported/returned OCR text is redacted
- **AND** v1 does not attempt to alter the image pixels or thumbnail

### Requirement: Export and MCP guardrails

Bulk export and MCP text responses SHALL return redacted content for protected
clips by default and include protected metadata. Raw protected content SHALL only
be included when the user has explicitly opted in or confirmed that egress.

#### Scenario: Default export redacts protected text

- **WHEN** the user exports clipboard history without enabling raw protected
  export
- **THEN** protected clips contain redacted text in the export
- **AND** the export marks those clips as protected

#### Scenario: MCP list and get responses are redacted by default

- **WHEN** an MCP client calls `list_recent`, `search_clipboard`, or `get_clip`
  for a protected clip
- **THEN** the response contains redacted content by default
- **AND** the response includes metadata indicating the clip is protected

#### Scenario: Raw protected egress requires explicit permission

- **WHEN** raw protected export or MCP access is disabled
- **THEN** no export or MCP response includes the raw sensitive span
- **AND** enabling raw protected egress requires an explicit user action

### Requirement: User settings and category control

Content Protection SHALL provide settings for a master enabled flag, individual
detector categories, and raw protected egress permissions. Built-in protection
SHALL be enabled by default.

#### Scenario: User disables a category

- **WHEN** the user disables the phone-number category
- **THEN** phone-number matches are no longer redacted
- **AND** other enabled categories continue to redact their matches

#### Scenario: Master toggle disables protection

- **WHEN** the user disables Content Protection
- **THEN** ClipTrace displays raw content according to the previous app behavior
- **AND** the user can re-enable protection without losing stored clips

### Requirement: Existing privacy boundaries remain intact

Content Protection SHALL NOT weaken existing concealed/transient pasteboard
filtering or script-rule authorization. Clips rejected by the existing sensitive
pasteboard marker filter SHALL still bypass storage and rule execution entirely.
User-authorized clipboard rules MAY continue to receive raw content after that
filter.

#### Scenario: Concealed pasteboard content bypasses storage and rules

- **WHEN** copied content carries a concealed or transient pasteboard marker
- **THEN** the clip is not stored
- **AND** Content Protection does not evaluate it
- **AND** no clipboard rule or script receives it

#### Scenario: Authorized rule receives raw content

- **WHEN** a stored protected clip is processed by an enabled user-authorized
  clipboard rule
- **THEN** the rule receives the raw clip content
- **AND** Content Protection still controls how the resulting clip is displayed
