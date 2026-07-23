# Roadmap

This roadmap is directional, not a promise. Clipth is local-first, privacy-first, and focused on native macOS productivity.

## Current Focus

- Keep clipboard monitoring reliable after window lifecycle changes.
- Make the open-source project easy to build, inspect, and contribute to.
- Improve trust materials: privacy docs, security reporting, release signing notes, and contribution guidance.
- Continue validating the end-to-end encrypted sync engine across more WebDAV and S3-compatible services.

## Near Term

### Distribution

- Publish a polished `v1.0.0` open-source release.
- Add Homebrew Cask distribution.
- Improve first-run install notes for self-signed vs notarized builds.
- Evaluate Apple notarization for public DMG releases.

### MCP

- Add MCP resources for favorites, pinned clips, and tag groups.
- Add MCP prompts such as clipboard summaries and time-bounded lookup helpers.
- Improve cross-process refresh when MCP writes modify the same database as the GUI.

### Privacy and Safety

- Keep expanding sensitive pasteboard-type handling.
- Document the local database location more precisely per release build.
- Add tests around URL tracking-parameter stripping.
- Add tests around search token parsing and retention behavior.

## Mid Term

### Sync

- Add a native CloudKit transport after the project moves to Developer ID signing and can ship the required iCloud container entitlements.
- Evaluate direct Dropbox, OneDrive, or Google Drive APIs only where their delta feeds add value beyond the existing local-folder backend.

### Power User Workflows

- Sequential paste stack.
- Text transform chains for paste-as actions.
- Snippet placeholders such as dates, UUIDs, cursor position, and recent clipboard references.
- Sidebar collections based on tags.

### Search and Preview

- Better OCR backfill controls.
- More source-app and time-query affordances.
- Optional URL metadata previews with a no-network mode.

### Reliability

- SwiftData schema migration tests.
- Large-image memory profiling.
- Better diagnostics for Accessibility permission and paste automation.

## Later

- Optional encrypted private clips.
- Shortcuts.app integration.
- Companion apps only after the macOS app is stable.
