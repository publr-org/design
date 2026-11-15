#!/usr/bin/env python3
"""The features people may upvote, from the parity checklist (editor/parity.md).

Writes design/features.ts (what the editor's Feature requests window lists) and
../../site/seed/features.json (the `feature` records publr.app starts with), so both name
every feature by the same key: its area and its name, `prototyping/flow-starting-point`.
Section 15 (keyboard shortcuts) is left out: a missing key is part of its feature.

    python3 scripts/features.py        # from publr-design/editor
"""
import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent.parent
PARITY = HERE / "parity.md"
OUT_TS = HERE / "design" / "features.ts"
OUT_SEED = HERE.parent.parent / "site" / "seed" / "features.json"
SKIP = {"Keyboard shortcuts"}

# What people see is ours: no name Figma owns (its products, features, programmes) and no
# other company's marks. parity.md, the internal reference, keeps Figma's words; these
# turn them into plain ones, and BANNED stops the script if any is left.
AREAS = {
    "AI features in Figma Design": "AI",
    "Dev Mode": "Developer handoff",
    "Editor chrome": "Interface",
}
TITLES = {
    "Figma menu (main menu)": "Main menu",
    "Dev Mode toggle": "Developer handoff mode",
    "Variables in Dev Mode": "Variables in developer handoff",
    "Dev Mode plugins": "Developer handoff plugins",
    "Figma-made plugins": "Built-in generated plugins",
    "Weave tools in Design": "AI image tools",
    "Figma agent": "Design agent",
    "First Draft / Make designs": "Generate designs from a prompt",
    "Make prototypes / Add interactions": "Generate prototype interactions",
    "AI add interactions / make prototype": "Add interactions with AI",
    "Make tool": "Code from a prompt",
    "Make image": "Generate image",
    "Code Connect": "Link components to code",
    "Code Connect UI": "Link components to code in the browser",
    "VS Code extension": "Code editor extension",
    "Ready for dev": "Mark as ready for development",
    "Ready for dev view": "Ready for development view",
    "Dev resources": "Developer resources",
    "Dev handoff": "Developer handoff",
}
WORDS = [
    (r"Figma Design file", "design file"),
    (r"Figma files", "design files"),
    (r"other Figma formats", "other formats"),
    (r"from Figma or the community", "from the community"),
    (r"from Figma and the community", "from the community"),
    (r"Figma Community", "Community"),
    (r"Source and Created by Figma filters", "source filters"),
    (r"Weave tools", "AI image tools"),
    (r"Dev Mode", "developer handoff"),
    (r"motion\.dev code", "animation code"),
    (r"Storybook, Jira, GitHub", "issue trackers and code"),
    (r", Slack, Teams", " and chat"),
    (r"\bE; ", ""),
]
# Release-note dates, plans and cross-references: "(2026-06, beta)", "(Org/Enterprise)".
NOTES = re.compile(r"\s*\((?:[^()]*\d{4}[^()]*|[^()]*beta[^()]*|see section \d+|Org/Enterprise|Schema \d{4})\)", re.I)
BANNED = re.compile(r"figma|figjam|weave|\bbuzz\b|dev mode|first draft|code connect|slack|jira|storybook|github|vs code", re.I)
# Make, the product, not the verb.
BANNED_CASED = re.compile(r"\bMake\b")


def clean(text: str) -> str:
    for pattern, plain in WORDS:
        text = re.sub(pattern, plain, text)
    return NOTES.sub("", text).strip()


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def area_of(heading: str) -> str:
    # "## 6. Properties" -> "Properties"; "## 16. Plugins and widgets (what the user sees)" -> "Plugins and widgets"
    name = re.sub(r"^\d+[a-z]?\.\s*", "", heading).strip()
    return re.sub(r"\s*\(.*\)$", "", name)


def main() -> None:
    features = []
    seen = set()
    area = ""
    for line in PARITY.read_text().splitlines():
        if line.startswith("## "):
            area = area_of(line[3:])
            continue
        m = re.match(r"^- \[([ x])\] ([^:]+?)(?::\s*(.*))?$", line)
        if not m or not area or area in SKIP or area == "Sources":
            continue
        done, name, what = m.group(1) == "x", m.group(2).strip(), (m.group(3) or "").strip()
        shown_area = AREAS.get(area, area)
        name = clean(TITLES.get(name, name))
        what = clean(what)
        for text in (shown_area, name, what):
            if BANNED.search(text) or BANNED_CASED.search(text):
                raise SystemExit(f"parity.md, {area} / {name}: '{text}' names a mark; add a plain word to features.py")
        key = f"{slug(shown_area)}/{slug(name)}"
        if key in seen:
            continue
        seen.add(key)
        features.append({"key": key, "title": name, "area": shown_area, "description": what, "status": "Built" if done else "Not built"})

    rows = "\n".join(
        f"  {{ key: {json.dumps(f['key'])}, title: {json.dumps(f['title'])}, area: {json.dumps(f['area'])}, description: {json.dumps(f['description'], ensure_ascii=False)} }},"
        for f in features
    )
    OUT_TS.write_text(
        "// The features people may upvote, by their line in the parity checklist (editor/parity.md),\n"
        "// written by scripts/features.py: do not edit by hand. A key is the line's area and name.\n"
        "// The Feature requests window lists these; publr.app holds their votes and status.\n\n"
        "export type Feature = { key: string; title: string; area: string; description: string };\n\n"
        f"export const FEATURES: Feature[] = [\n{rows}\n];\n"
    )
    OUT_SEED.write_text(json.dumps(features, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(features)} features -> {OUT_TS.name}, {OUT_SEED}")


if __name__ == "__main__":
    main()
