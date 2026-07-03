#!/usr/bin/env python3
"""Regenerate the `Avatar` and `Weapon` name->id enums in zzz_names.zig from
EnkaNetwork's ZZZ dataset.

These enums are pure name->id lookup tables (see the doc comments in zzz_names.zig):
edit-save.zig only ever materializes the entries that builds.zon actually references,
so every entry here is inert until a build names it. Pre-populating them means
the add-build skill can resolve an already-released character/W-Engine by name without the
manual EnkaNetwork id-resolution dance, and inspect-save can show every owned item by
name instead of a raw id.

The script rewrites only the lines BETWEEN the `// <gen:avatar>` / `// </gen:avatar>`
(and weapon) marker comments already present in zzz_names.zig; the doc comments, the
`Set`/`Stat` enums, and the reverse-lookup helpers are left untouched. Re-running on an
unchanged dataset is a no-op (idempotent).

Usage:
    python tools/builds/gen_names.py            # fetch live data, rewrite tools/builds/zzz_names.zig
    python tools/builds/gen_names.py --dir DIR  # read avatars/weapons/locs.json from DIR instead
    python tools/builds/gen_names.py --check    # generate but do not write; exit 1 if it would change

Data sources (same lineage the Set ids came from):
    store/zzz/avatars.json  id -> { Name: <codename>, ... }
    store/zzz/weapons.json  id -> { ItemName: <codename>, ImagePath: ".../Weapon_S_xxxx.png", ... }
    store/zzz/locs.json     { "en": { <codename>: <display name>, ... }, ... }
"""

import argparse
import json
import os
import re
import sys
import urllib.request

BASE = "https://raw.githubusercontent.com/EnkaNetwork/API-docs/master/store/zzz"
FILES = ("avatars.json", "weapons.json", "locs.json")
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

ZZZ_NAMES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zzz_names.zig")


def load(name, src_dir):
    """Load one dataset file from src_dir (if given) or by fetching it live."""
    if src_dir:
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(f"{BASE}/{name}", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def pascal(name):
    """Skill PascalCase rule: split on every non-alphanumeric (drops spaces, punctuation,
    apostrophes, brackets), capitalize each part's first letter, keep the rest as-is. Returns
    a valid Zig identifier, or '' if nothing usable remains."""
    parts = [p for p in re.split(r"[^0-9A-Za-z]+", name) if p]
    ident = "".join(p[0].upper() + p[1:] for p in parts)
    if ident and ident[0].isdigit():
        ident = "_" + ident  # Zig identifiers may not start with a digit
    return ident


def entries(data, loc_en, codename_key, placeholder_prefix, comment_fn):
    """Build a sorted-by-id list of (ident, id, comment) rows, disambiguating any identifier
    collisions and falling back to a numeric placeholder when the name does not resolve."""
    rows = []
    seen = {}
    for sid in sorted(data, key=int):
        info = data[sid]
        iid = int(sid)
        codename = info.get(codename_key, "")
        display = loc_en.get(codename, "")
        ident = pascal(display) if display else ""
        if not ident:
            ident = f"{placeholder_prefix}{iid}"  # unresolved name -> numeric placeholder
        if ident in seen and seen[ident] != iid:
            ident = f"{ident}_{iid}"  # identifier collision between two display names
        seen[ident] = iid
        rows.append((ident, iid, comment_fn(info, iid, codename, display)))
    return rows


def avatar_comment(info, iid, codename, display):
    return codename or "(name not in dataset)"


def weapon_comment_factory(avatar_display):
    """Weapon comment = the image-basename codename (e.g. Weapon_S_1491), plus the owning
    character in parens for a signature engine whose basename id is a known avatar."""
    def fn(info, iid, codename, display):
        img = info.get("ImagePath", "")
        base = os.path.splitext(os.path.basename(img))[0] if img else codename
        base = base or f"weapon {iid}"
        m = re.fullmatch(r"Weapon_S_(\d+)", base)
        if m and int(m.group(1)) in avatar_display:
            return f"{base} ({avatar_display[int(m.group(1))]})"
        return base
    return fn


def render(rows):
    return [f"    {ident} = {iid}, // {comment}" for ident, iid, comment in rows]


def splice(lines, tag, new_lines):
    """Replace the lines strictly between `// <gen:tag>` and `// </gen:tag>`."""
    open_i = next(i for i, l in enumerate(lines) if f"<gen:{tag}>" in l)
    close_i = next(i for i, l in enumerate(lines) if f"</gen:{tag}>" in l)
    return lines[: open_i + 1] + new_lines + lines[close_i:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", help="read the three JSON files from this dir instead of fetching")
    ap.add_argument("--check", action="store_true", help="do not write; exit 1 if it would change")
    args = ap.parse_args()

    avatars = load("avatars.json", args.dir)
    weapons = load("weapons.json", args.dir)
    loc_en = load("locs.json", args.dir)["en"]

    avatar_rows = entries(avatars, loc_en, "Name", "Avatar", avatar_comment)
    avatar_display = {iid: loc_en.get(avatars[str(iid)].get("Name", ""), "") for _, iid, _ in avatar_rows}
    avatar_display = {k: v for k, v in avatar_display.items() if v}
    weapon_rows = entries(weapons, loc_en, "ItemName", "Weapon", weapon_comment_factory(avatar_display))

    with open(ZZZ_NAMES, encoding="utf-8", newline="") as f:
        content = f.read()
    eol = "\r\n" if "\r\n" in content else "\n"
    lines = content.split(eol)

    lines = splice(lines, "avatar", render(avatar_rows))
    lines = splice(lines, "weapon", render(weapon_rows))
    new_content = eol.join(lines)

    print(f"avatars: {len(avatar_rows)}  weapons: {len(weapon_rows)}")
    if new_content == content:
        print("zzz_names.zig already up to date (no change).")
        return 0
    if args.check:
        print("zzz_names.zig WOULD change (run without --check to write).", file=sys.stderr)
        return 1
    with open(ZZZ_NAMES, "w", encoding="utf-8", newline="") as f:
        f.write(new_content)
    print(f"wrote {ZZZ_NAMES}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
