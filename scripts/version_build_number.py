#!/usr/bin/env python3
"""Convert a public semver into Sparkle/Xcode's internal build number.

Sparkle compares appcast `sparkle:version` with the app bundle's
`CFBundleVersion`. Older Clipth releases shipped with CFBundleVersion=1,
so pre-1.0 public versions like 0.9.12 must map to a build number greater
than 1 or those older builds will think they are already newer.
"""

import re
import sys


def build_number(version: str) -> int:
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", version.strip())
    if not match:
        raise ValueError(f"expected semantic version x.y.z, got {version!r}")

    major, minor, patch = (int(part) for part in match.groups())
    return major * 1_000_000 + minor * 1_000 + patch


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: version_build_number.py <x.y.z>", file=sys.stderr)
        raise SystemExit(2)

    try:
        print(build_number(sys.argv[1]))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
