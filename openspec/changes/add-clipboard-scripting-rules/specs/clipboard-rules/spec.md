## ADDED Requirements

### Requirement: Rule definition

A rule SHALL consist of (1) a set of zero or more match conditions, (2) exactly one action, and (3) metadata: a user-facing name, an enabled flag, and a position in an ordered list. Rules SHALL be persisted across launches. A rule whose enabled flag is false SHALL never run, automatically or manually.

#### Scenario: A rule round-trips through persistence
- **WHEN** the user creates a rule, quits, and relaunches ClipTrace
- **THEN** the rule reappears with its name, conditions, action, enabled state, and ordinal position intact

#### Scenario: Disabled rules never run
- **WHEN** a rule's enabled flag is false and a clip matching its conditions is captured
- **THEN** the rule's action does not execute and the clip is stored unchanged

### Requirement: Match conditions

The engine SHALL support match conditions on clip type (text, image, url, video, file, rtf), content matching a user-supplied regular expression, source application bundle identifier, and content character-length bounds (minimum and/or maximum). When a rule specifies multiple conditions, ALL specified conditions MUST hold for the rule to match (logical AND). A rule with no conditions SHALL match every (non-sensitive) clip. An invalid regular expression SHALL cause the rule to be treated as non-matching rather than crash, and the invalidity SHALL be surfaced to the user when editing the rule.

#### Scenario: Type plus regex both required
- **WHEN** a rule requires type = text AND content matching `^\{.*\}$`, and an image clip is captured
- **THEN** the rule does not match (the type condition fails even if other conditions would pass)

#### Scenario: Regex matches text content
- **WHEN** a rule requires content matching `sk-[A-Za-z0-9]{20,}` and a clip containing `sk-ABCD...` is captured
- **THEN** the rule matches

#### Scenario: Invalid regex is inert, not fatal
- **WHEN** a rule's regex fails to compile
- **THEN** the rule matches nothing, no clip processing crashes, and the editor flags the regex as invalid

### Requirement: Automatic evaluation on capture

When a new clip is captured (and has passed the sensitive-content filter — see the exclusion invariant), the engine SHALL evaluate enabled rules in their list order and run the action of each rule that matches. Evaluation order SHALL be deterministic and follow the user-defined ordinal positions.

#### Scenario: Ordered evaluation
- **WHEN** two enabled rules both match a captured clip
- **THEN** their actions run in ascending ordinal order

#### Scenario: Non-matching rules are skipped
- **WHEN** a captured clip matches rule B but not rule A
- **THEN** only rule B's action runs

### Requirement: Manual invocation

The user SHALL be able to run any single rule on demand against a selected clip from the clip row's context menu, regardless of whether that rule's conditions match. Manual invocation SHALL apply the same action and Effect semantics as automatic invocation.

#### Scenario: Run a rule from the context menu
- **WHEN** the user right-clicks a clip and selects a rule by name
- **THEN** that rule's action runs against the clip and its Effect is applied

#### Scenario: Manual run ignores conditions
- **WHEN** the user manually runs a rule whose match conditions the clip does not satisfy
- **THEN** the action still runs (conditions gate automatic firing only, not manual invocation)

### Requirement: Non-blocking script execution

Script-backed actions (shell or JavaScript) SHALL execute asynchronously after the captured clip has already been stored, so that clipboard monitoring and the UI are never blocked by a slow, hung, or long-running script. A script that never terminates SHALL NOT prevent subsequent clips from being captured and stored.

#### Scenario: Slow script does not stall capture
- **WHEN** a matched rule runs a script that sleeps for several seconds and the user copies three more clips meanwhile
- **THEN** all three subsequent clips are captured and stored without delay, and the slow script's Effect is applied when (and if) it completes

#### Scenario: Clip is visible before its script finishes
- **WHEN** a clip matches a script rule
- **THEN** the clip appears in history immediately, and any Effect from the script (e.g. replaced text or added tags) is applied afterward

### Requirement: Synchronous pre-insert exclusion tier

A rule whose conditions are evaluable without running user code (type, regex, source app, length) and whose action is `drop` SHALL be allowed to run synchronously before the clip is inserted, preventing it from ever being stored — preserving the behavior of the current exclude filter. All other actions defer to the asynchronous post-insert path.

#### Scenario: Regex drop prevents storage entirely
- **WHEN** a code-free rule with action `drop` matches a captured clip
- **THEN** the clip is never inserted into history (it does not flash in and then disappear)

### Requirement: Effect application

A rule action SHALL produce exactly one Effect from the set { `replaceText`, `newClip`, `setTags`, `rename`, `copyToPasteboard`, `drop`, `none` }, and the engine SHALL apply that Effect by reusing the existing view-model operations (content update, insert, set tags, rename, copy to clipboard, soft-delete). Applying an Effect SHALL NOT itself be recorded as a new user copy that re-triggers rule evaluation (no capture loops).

#### Scenario: replaceText updates the clip in place
- **WHEN** a rule returns `replaceText` with new content
- **THEN** the existing clip's content is updated to the new value and its row reflects the change

#### Scenario: setTags reuses the tagging verb
- **WHEN** a rule returns `setTags` with `["json"]`
- **THEN** the clip gains the `json` tag via the same path as manual tagging

#### Scenario: Effects do not cause capture loops
- **WHEN** a rule's Effect writes to the pasteboard or mutates the clip
- **THEN** that write is treated as internal and does not re-enter rule evaluation

### Requirement: Multiple-match resolution

When several rules match one clip, the engine SHALL run them in order; a `drop` Effect SHALL halt evaluation and exclude the clip from history (removing it if already stored), while any non-`drop` Effect SHALL apply and allow evaluation to continue with the (possibly transformed) clip. Later rules in the chain SHALL observe content produced by earlier `replaceText` Effects.

#### Scenario: drop short-circuits the chain
- **WHEN** rule A returns `replaceText` and rule B (later) returns `drop`
- **THEN** rule A's transform is moot because the clip is dropped, and no rule after B runs

#### Scenario: Transform then tag chains
- **WHEN** rule A returns `replaceText` (pretty-printed JSON) and rule B (later) matches the transformed content and returns `setTags`
- **THEN** rule B sees the pretty-printed content and tags the clip accordingly

### Requirement: Sensitive-content exclusion invariant

The rule engine SHALL only ever evaluate and run against clips that have already passed ClipTrace's concealed/transient/sensitive pasteboard-type filter. Clips bearing those markers (e.g. password-manager fields) SHALL NOT be passed to any rule, condition evaluation, or script under any circumstance.

#### Scenario: Concealed clip bypasses all rules
- **WHEN** content marked `org.nspasteboard.ConcealedType` is copied
- **THEN** no rule is evaluated against it, no script receives it, and it is not stored
