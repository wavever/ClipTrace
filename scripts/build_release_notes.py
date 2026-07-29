#!/usr/bin/env python3
"""Build the Sparkle appcast.xml and the GitHub Release body for one release.

The Sparkle update dialog renders the appcast item's <description> as HTML, so
we embed the *full* changelog there instead of a "see the release page" stub —
otherwise users only ever see a bare link in the updater. Notes can be authored
bilingually: drop a <version>.md with `## en` / `## zh` into NOTES_DIR (the notes
live in the wavever/clipth-website repo, which release.yml checks out) and each
language is emitted as its own <description xml:lang="…">,
which Sparkle picks from based on the user's system language. When no notes file
exists we fall back to an auto-generated English changelog built from
conventional-commit subjects between the previous tag and this one.

This lives as a script (rather than inline in release.yml) so it can be run and
eyeballed locally before cutting a release.

Env inputs:
  VERSION, BUILD_VERSION, TAG, REPO (owner/repo), DMG_URL, ED_SIG, LENGTH
  PREV_TAG       previous git tag (may be empty → no history/diff)
  PREV_APPCAST   path to the previous appcast.xml (may be missing → no history)
  NOTES_DIR      dir holding <version>.md (default: docs/release-notes, which is
                 the layout inside the checked-out clipth-website repo)
  OUT_APPCAST    where to write the merged appcast.xml (default: appcast.xml)
  OUT_BODY       where to write the GitHub Release body markdown
  PUBDATE        RFC-822 date for the appcast item
"""

import html
import os
import re
import subprocess
import sys

from version_build_number import build_number

VERSION = os.environ["VERSION"]
BUILD_VERSION = os.environ.get("BUILD_VERSION", "").strip()
TAG = os.environ["TAG"]
REPO = os.environ["REPO"]
DMG_URL = os.environ["DMG_URL"]
ED_SIG = os.environ.get("ED_SIG", "")
LENGTH = os.environ.get("LENGTH", "")
PREV_TAG = os.environ.get("PREV_TAG", "").strip()
PREV_APPCAST = os.environ.get("PREV_APPCAST", "").strip()
NOTES_DIR = os.environ.get("NOTES_DIR", "docs/release-notes")
OUT_APPCAST = os.environ.get("OUT_APPCAST", "appcast.xml")
OUT_BODY = os.environ.get("OUT_BODY", "")
PUBDATE = os.environ.get("PUBDATE", "")
APP_NAME = "Clipth"


if not BUILD_VERSION:
    BUILD_VERSION = str(build_number(VERSION))

REPO_URL = f"https://github.com/{REPO}"
RELEASE_URL = f"{REPO_URL}/releases/tag/{TAG}"
COMPARE_URL = (
    f"{REPO_URL}/compare/{PREV_TAG}...{TAG}" if PREV_TAG else f"{REPO_URL}/commits/{TAG}"
)

# Footer line linking back to the full release page, per language.
FOOTER = {
    "en": f'<p>Full changelog: <a href="{RELEASE_URL}">{TAG}</a></p>',
    "zh-Hans": f'<p>完整更新日志：<a href="{RELEASE_URL}">{TAG}</a></p>',
}


# --------------------------------------------------------------------------- #
# Auto changelog (fallback) — categorize conventional-commit subjects.
# --------------------------------------------------------------------------- #
def auto_english_markdown() -> str:
    rng = f"{PREV_TAG}..{TAG}" if PREV_TAG else TAG
    raw = subprocess.check_output(
        ["git", "log", rng, "--no-merges", "--pretty=format:%H%x1f%s%x1e"],
        text=True,
    )

    categories = [
        ("Features", r"feat"),
        ("Bug Fixes", r"fix"),
        ("Performance", r"perf"),
        ("Refactoring", r"refactor"),
        ("Documentation", r"docs"),
        ("Build & CI", r"(build|ci)"),
        ("Chores", r"chore"),
    ]
    prefix_re = re.compile(r"^[a-zA-Z]+(\([^)]*\))?!?:\s*")
    bump_re = re.compile(r"^chore.*bump version", re.I)

    grouped = {title: [] for title, _ in categories}
    other = []

    for record in raw.split("\x1e"):
        record = record.strip("\r\n")
        if not record:
            continue
        parts = record.split("\x1f", 1)
        if len(parts) < 2:
            continue
        sha, subject = parts[0], parts[1]
        if bump_re.match(subject):
            continue
        clean = prefix_re.sub("", subject).strip()
        entry = f"- {clean}"
        matched = None
        for title, pat in categories:
            if re.match(rf"^{pat}(\([^)]*\))?!?:", subject, re.I):
                matched = title
                break
        (grouped[matched] if matched else other).append(entry)

    lines = []
    for title, _ in categories:
        if grouped[title]:
            lines.append(f"### {title}")
            lines.extend(grouped[title])
            lines.append("")
    if other:
        lines.append("### Other Changes")
        lines.extend(other)
        lines.append("")
    return "\n".join(lines).strip()


# --------------------------------------------------------------------------- #
# Bilingual notes file parsing.
# --------------------------------------------------------------------------- #
def parse_bilingual(text: str) -> dict:
    """Split a notes file into language bodies keyed by 'en' / 'zh-Hans'.

    Sections are delimited by level-2 headers whose title names a language,
    e.g. `## en`, `## English`, `## zh`, `## 中文`. Anything before the first
    such header is ignored.
    """
    sections = {}
    current = None
    buf = []

    def flush():
        if current and buf:
            sections.setdefault(current, "\n".join(buf).strip())

    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m and not line.startswith("###"):
            flush()
            buf = []
            title = m.group(1).strip().lower()
            if title.startswith("en") or "english" in title:
                current = "en"
            elif title.startswith("zh") or "中文" in title or "chinese" in title:
                current = "zh-Hans"
            else:
                current = None
            continue
        if current is not None:
            buf.append(line)
    flush()
    return sections


# --------------------------------------------------------------------------- #
# Minimal Markdown → HTML for the subset we author (headings, lists,
# paragraphs, inline links / code / bold). Sparkle renders this in a WebView.
# --------------------------------------------------------------------------- #
def _inline(text: str) -> str:
    text = html.escape(text)
    # `code`
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    # **bold**
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    # [label](url)  — label/url already HTML-escaped above
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def markdown_to_html(md: str) -> str:
    out = []
    in_list = False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            close_list()
            continue
        h = re.match(r"^(#{1,6})\s+(.*)$", line)
        if h:
            close_list()
            # Notes use `###` for category headings; render them as <h3>. Any
            # shallower heading collapses to <h2>. Sparkle's WebView styles both.
            level = 3 if len(h.group(1)) >= 3 else 2
            out.append(f"<h{level}>{_inline(h.group(2).strip())}</h{level}>")
            continue
        li = re.match(r"^[-*]\s+(.*)$", line)
        if li:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_inline(li.group(1).strip())}</li>")
            continue
        close_list()
        out.append(f"<p>{_inline(line.strip())}</p>")
    close_list()
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# Appcast assembly.
# --------------------------------------------------------------------------- #
def previous_items() -> str:
    """Return prior <item> blocks (excluding this version) to preserve history."""
    if not PREV_APPCAST or not os.path.exists(PREV_APPCAST):
        return ""
    xml = open(PREV_APPCAST).read()
    channel_title = re.search(r"<channel>.*?<title>(.*?)</title>", xml, flags=re.S)
    if not channel_title or html.unescape(channel_title.group(1).strip()) != APP_NAME:
        print("Previous appcast belongs to a different app identity; starting fresh history.")
        return ""

    items = re.findall(r"<item>.*?</item>", xml, flags=re.S)
    seen = {VERSION, BUILD_VERSION}
    kept = []
    for item in items:
        m = re.search(r"<sparkle:version>(.*?)</sparkle:version>", item)
        v = m.group(1).strip() if m else ""
        short = re.search(r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>", item)
        short_v = short.group(1).strip() if short else ""
        if v in seen or short_v == VERSION:
            continue
        if v:
            seen.add(v)
        kept.append(item.rstrip())
    return "\n".join(kept)


def description_block(lang: str, body_html: str) -> str:
    footer = FOOTER.get(lang, "")
    inner = f"{body_html}\n{footer}".strip()
    return (
        f'            <description xml:lang="{lang}"><![CDATA[\n'
        f"{inner}\n"
        f"            ]]></description>"
    )


def main() -> None:
    notes_path = os.path.join(NOTES_DIR, f"{VERSION}.md")
    sections = {}
    if os.path.exists(notes_path):
        sections = parse_bilingual(open(notes_path).read())
        print(f"Using authored notes: {notes_path} (languages: {sorted(sections)})")
    else:
        print(f"No authored notes at {notes_path}; auto-generating English changelog.")

    en_md = sections.get("en") or auto_english_markdown()
    zh_md = sections.get("zh-Hans")

    descriptions = [description_block("en", markdown_to_html(en_md))]
    if zh_md:
        descriptions.append(description_block("zh-Hans", markdown_to_html(zh_md)))

    item = "\n".join(
        [
            "        <item>",
            f"            <title>Version {VERSION}</title>",
            f"            <link>{RELEASE_URL}</link>",
            f"            <sparkle:version>{BUILD_VERSION}</sparkle:version>",
            f"            <sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>",
            "            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>",
            *descriptions,
            f"            <pubDate>{PUBDATE}</pubDate>",
            f'            <enclosure url="{DMG_URL}" sparkle:edSignature="{ED_SIG}" '
            f'length="{LENGTH}" type="application/octet-stream" />',
            "        </item>",
        ]
    )

    prev = previous_items()
    prev_block = ("\n" + prev) if prev else ""

    appcast = (
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "    <channel>\n"
        f"        <title>{APP_NAME}</title>\n"
        f"        <link>{REPO_URL}</link>\n"
        f"        <description>{APP_NAME} release feed</description>\n"
        "        <language>en</language>\n"
        f"{item}{prev_block}\n"
        "    </channel>\n"
        "</rss>\n"
    )
    with open(OUT_APPCAST, "w") as f:
        f.write(appcast)
    print(f"Wrote {OUT_APPCAST}")

    if OUT_BODY:
        parts = []
        if zh_md:
            parts.append("## English\n\n" + en_md)
            parts.append("## 中文\n\n" + zh_md)
        else:
            parts.append(en_md)
        parts.append(f"**Full Changelog**: {COMPARE_URL}")
        with open(OUT_BODY, "w") as f:
            f.write("\n\n".join(parts).strip() + "\n")
        print(f"Wrote {OUT_BODY}")


if __name__ == "__main__":
    main()
