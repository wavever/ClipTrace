# Security Policy

ClipTrace handles clipboard history, so security and privacy reports are treated seriously even when the issue looks small.

## Supported Versions

Security fixes target:

- The latest GitHub Release
- The `main` branch

Older tags are best-effort only.

## Reporting a Vulnerability

Please do not open a public issue for vulnerabilities that expose private clipboard data, bypass privacy settings, enable unintended MCP access, or otherwise put users at risk.

Preferred reporting path:

1. Use GitHub private vulnerability reporting if it is enabled for this repository.
2. If private reporting is unavailable, contact the maintainer through the GitHub profile and include a minimal description first.

Please include:

- Affected version or commit
- macOS version
- Reproduction steps
- Expected vs actual behavior
- Whether the issue requires MCP, Accessibility permission, update checks, or a specific source app
- Any logs or screenshots with secrets removed

## Scope

Security-sensitive areas include:

- Clipboard capture and sensitive pasteboard-type handling
- Local database persistence and deletion behavior
- MCP read/write tools
- Update signing and release packaging
- Accessibility-driven paste behavior
- Screen-recording exclusion behavior

## Disclosure

The goal is coordinated disclosure:

1. Confirm the issue.
2. Prepare a fix or mitigation.
3. Release the fix.
4. Credit the reporter if they want credit.

Do not share exploit details publicly before users have a reasonable path to update.
