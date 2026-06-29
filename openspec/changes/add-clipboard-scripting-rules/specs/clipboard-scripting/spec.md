## ADDED Requirements

### Requirement: Shell action contract

A shell action SHALL run a user-designated executable script file with a defined I/O contract: the clip's text content is written to the script's standard input; clip metadata is exposed via environment variables `CLIP_TYPE`, `CLIP_SOURCE_APP`, `CLIP_BUNDLE_ID`, and `CLIP_TAGS`; for image clips the bytes are written to a temporary file whose path is provided in `CLIP_IMAGE_PATH`. The script's standard output SHALL be interpreted as the result text, and an exit code of 0 SHALL mean "apply the result" while any non-zero exit code SHALL mean "skip / no Effect." A script MAY instead emit a JSON object on standard output to request a richer Effect (e.g. tags, rename, drop).

#### Scenario: stdin to stdout transform
- **WHEN** a shell rule runs a script that reads stdin, uppercases it, and prints it, against a text clip "hello"
- **THEN** the clip's content becomes "HELLO" via a `replaceText` Effect

#### Scenario: Non-zero exit skips the Effect
- **WHEN** a shell script exits with a non-zero code
- **THEN** no Effect is applied and the clip is left unchanged

#### Scenario: Metadata is available to the script
- **WHEN** a shell script reads `CLIP_SOURCE_APP` and `CLIP_BUNDLE_ID`
- **THEN** those variables hold the capturing application's name and bundle identifier

#### Scenario: Image clip is passed as a file path
- **WHEN** an image clip triggers a shell rule
- **THEN** `CLIP_IMAGE_PATH` points to a readable temporary file containing the image bytes, and that file is removed after the run

### Requirement: JavaScript action contract

A JavaScript action SHALL run user-supplied source in an embedded JavaScriptCore context with an injected `clip` object exposing at least `clip.text`, `clip.type`, `clip.sourceApp`, and `clip.tags`. The script's value SHALL be interpreted as the Effect: returning a string requests `replaceText`; returning an object with optional `text`, `tags`, `title`, and `drop` fields requests the corresponding richer Effect; returning nothing/undefined requests `none`.

#### Scenario: Returning a string replaces content
- **WHEN** a JS rule returns `clip.text.trim()`
- **THEN** the clip's content is replaced with the trimmed text

#### Scenario: Returning an object sets multiple effects
- **WHEN** a JS rule returns `{ text: pretty, tags: ["json"], title: "Config" }`
- **THEN** the clip's content, tags, and custom title are all updated accordingly

#### Scenario: Returning nothing is a no-op
- **WHEN** a JS rule returns `undefined`
- **THEN** the clip is left unchanged

### Requirement: Default-deny JavaScript capabilities

The JavaScript runtime SHALL NOT expose network access, filesystem access, or process execution by default. Such host capabilities SHALL only be reachable when explicitly granted on the specific rule, and a rule with no granted capabilities SHALL be limited to pure computation over the injected `clip` data.

#### Scenario: No ambient network in JS
- **WHEN** a JS rule with no granted capabilities attempts a network fetch
- **THEN** no network call is made (the capability is absent), and the rule either errors or returns no Effect without exfiltrating data

#### Scenario: Capability requires explicit grant
- **WHEN** the user has not enabled the network capability on a rule
- **THEN** the rule cannot reach any host-provided network function

### Requirement: Execution timeout and cancellation

Every script run (shell or JavaScript) SHALL be bounded by a timeout. When a run exceeds the timeout, it SHALL be cancelled/terminated, no Effect SHALL be applied, and the timeout SHALL be reported as an error. A timed-out or terminated run SHALL NOT leave the app, the capture pipeline, or the model context in a wedged state.

#### Scenario: Hung shell script is killed
- **WHEN** a shell script runs longer than the configured timeout
- **THEN** the process is terminated, no Effect is applied, and an error is recorded

#### Scenario: Infinite JS loop is interrupted
- **WHEN** a JS rule enters an infinite loop
- **THEN** execution is interrupted at the timeout, no Effect is applied, and an error is recorded

### Requirement: Managed scripts directory

Shell scripts SHALL be resolved from a managed directory under the application's Application Support location (`~/Library/Application Support/ClipTrace/Scripts/`). The app SHALL provide a way to reveal this directory. Only regular, executable files within the managed directory tree SHALL be runnable as shell actions.

#### Scenario: Reveal the scripts directory
- **WHEN** the user chooses to open the scripts folder from settings
- **THEN** the managed `Scripts/` directory is revealed in Finder, created if it did not yet exist

### Requirement: Enable-time authorization gate

Before any rule with a script (shell or JavaScript) action can be enabled, the user SHALL be required to explicitly confirm that the rule may run code automatically against captured clipboard content. A script rule SHALL remain inert until this confirmation is given.

#### Scenario: Confirmation required to arm a script rule
- **WHEN** the user toggles a shell/JS rule to enabled for the first time
- **THEN** an explicit confirmation is presented, and the rule only becomes active after the user confirms

#### Scenario: Declining leaves the rule disabled
- **WHEN** the user declines the confirmation
- **THEN** the rule stays disabled and no script runs

### Requirement: Error surfacing and run log

Script failures (non-zero exit, JS exceptions, timeouts) SHALL be surfaced to the user through the existing toast/notification layer, and the app SHALL retain a recent-run log recording, per run, the rule, outcome (applied / skipped / error), and timestamp, viewable from settings.

#### Scenario: Failure raises a toast
- **WHEN** a script rule errors during an automatic run
- **THEN** a toast informs the user which rule failed, without disrupting clipboard capture

#### Scenario: Runs are logged
- **WHEN** rules have run automatically or manually
- **THEN** settings shows a recent-run log with rule name, outcome, and time for each run

### Requirement: Unified Effect output

Both the shell and JavaScript backends SHALL converge their results onto a single Effect model — `replaceText`, `newClip`, `setTags`, `rename`, `copyToPasteboard`, `drop`, or `none` — so that the rule engine applies any backend's output through one code path.

#### Scenario: Both backends produce the same Effect type
- **WHEN** a shell script prints JSON requesting tags and a JS rule returns an object requesting tags
- **THEN** both are applied by the engine via the identical `setTags` Effect path
