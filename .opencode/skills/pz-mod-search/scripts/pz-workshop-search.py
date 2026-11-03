#!/usr/bin/env python3
"""pz-workshop-search.py — find and vet Project Zomboid Workshop mods.

Companion to `nix run .#pz-workshop` (collections/packs). This script covers
DISCOVERY: keyword search, metadata, and the authoritative mod.info check.

    search <query>...        browse the Workshop for keywords
    details <id>...          tags, subscribers, updated, declared Mod ID/deps
    verify <id>...           download with steamcmd and print every mod.info

Examples
--------
    ./pz-workshop-search.py search sewing tailoring --pages 5 --b42 --mp
    ./pz-workshop-search.py search "car repair" --pages 2 --b42 --json
    ./pz-workshop-search.py details 3522680786 3816028300
    ./pz-workshop-search.py verify 3522680786 3816028300 --dir ~/pzws

Why `verify` exists
-------------------
Descriptions lie or omit things. `mod.info` is the only authority for the
`Mods=` value (`id=`), for `require=` dependencies (often not in the
description), for `incompatible=`, and for the fact that ONE Workshop item can
ship SEVERAL mods (balance tiers, per-pack addons, an uninstall/safe-removal
mod). Always run `verify` before writing a pack entry.

steamcmd runs under bubblewrap here: it can only write under $HOME. Point
`--dir` at a home directory, not /tmp.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

APP_ID = "108600"
BROWSE = "https://steamcommunity.com/workshop/browse/"
DETAILS = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
UA = {"User-Agent": "Mozilla/5.0 (pz-workshop-search)"}
ITEM_RE = re.compile(r'sharedfiles/filedetails/\?id=(\d+)"[^>]*>\s*([^<]*)</a>')
MOD_ID_RE = re.compile(r"(?:Mod ID|Workshop ID)\s*:?\s*([A-Za-z0-9_\-\.]+)", re.I)


def get(url: str, data: bytes | None = None, timeout: int = 40) -> bytes:
    req = urllib.request.Request(url, data=data, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def browse(query: str, page: int, b42: bool) -> list[tuple[str, str]]:
    params = {
        "appid": APP_ID,
        "searchtext": query,
        "browsesort": "textsearch",
        "section": "readytouseitems",
        "p": str(page),
    }
    if b42:
        params["requiredtags[]"] = "Build 42"
    html = get(BROWSE + "?" + urllib.parse.urlencode(params)).decode("utf-8", "replace")
    return [
        (i, t.replace("&amp;", "&").replace("&#39;", "'").strip())
        for i, t in ITEM_RE.findall(html)
    ]


def details(ids: list[str]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for i in range(0, len(ids), 50):
        chunk = ids[i : i + 50]
        body = urllib.parse.urlencode(
            {"itemcount": len(chunk), **{f"publishedfileids[{j}]": v for j, v in enumerate(chunk)}}
        ).encode()
        for attempt in range(3):
            try:
                payload = json.loads(get(DETAILS, data=body))["response"]["publishedfiledetails"]
                break
            except Exception as e:  # network flake; retry twice
                if attempt == 2:
                    raise
                print(f"retry ({e})", file=sys.stderr)
                time.sleep(2)
        for item in payload:
            out[item["publishedfileid"]] = item
        time.sleep(0.3)
    return out


def tags_of(item: dict) -> list[str]:
    return [t["tag"] for t in item.get("tags", [])]


def date_of(item: dict) -> str:
    return datetime.date.fromtimestamp(item["time_updated"]).isoformat()


def declared_mod_ids(item: dict) -> list[str]:
    desc = re.sub(r"\[/?[^\]]*\]", " ", item.get("description", "") or "")
    seen: list[str] = []
    for m in MOD_ID_RE.finditer(desc):
        v = m.group(1)
        if v not in seen and not v.isdigit():
            seen.append(v)
    return seen


def cmd_search(args: argparse.Namespace) -> int:
    found: dict[str, dict] = {}
    for q in args.query:
        for page in range(1, args.pages + 1):
            try:
                items = browse(q, page, args.b42)
            except Exception as e:
                print(f"{q} page {page}: {e}", file=sys.stderr)
                break
            new = 0
            for iid, title in items:
                if iid not in found:
                    found[iid] = {"id": iid, "title": title, "queries": [q]}
                    new += 1
                elif q not in found[iid]["queries"]:
                    found[iid]["queries"].append(q)
            if new == 0 and page > 1:
                break
            time.sleep(0.25)
        print(f"  {q}: {len(found)} unique so far", file=sys.stderr)

    rows = list(found.values())
    if args.b42 or args.mp:
        meta = details([r["id"] for r in rows])
        kept = []
        for r in rows:
            item = meta.get(r["id"])
            if not item:
                continue
            tags = tags_of(item)
            if args.b42 and "Build 42" not in tags:
                continue
            if args.mp and "Multiplayer" not in tags:
                continue
            r.update(tags=tags, subs=item.get("subscriptions", 0), updated=date_of(item))
            kept.append(r)
        rows = kept

    rows.sort(key=lambda r: (-r.get("subs", 0), r["title"].lower()))
    if args.limit:
        rows = rows[: args.limit]

    if args.json:
        print(json.dumps(rows, indent=1))
    else:
        for r in rows:
            flags = []
            if r.get("tags"):
                flags.append("B42" if "Build 42" in r["tags"] else "---")
                flags.append("MP" if "Multiplayer" in r["tags"] else "  ")
            print(
                f'{r["id"]}  {" ".join(flags):5}  {r.get("subs", ""):>8}  '
                f'{r.get("updated", ""):10}  {r["title"][:80]}'
            )
    print(f"{len(rows)} item(s)", file=sys.stderr)
    return 0


def cmd_details(args: argparse.Namespace) -> int:
    meta = details(args.id)
    if args.json:
        print(json.dumps(meta, indent=1))
        return 0
    for iid in args.id:
        item = meta.get(iid)
        if not item:
            print(f"{iid}  (not returned — removed, private, or wrong id)")
            continue
        tags = tags_of(item)
        print(
            f'{iid}  {item.get("title", "")}\n'
            f'  updated {date_of(item)}  subs {item.get("subscriptions", 0)}  '
            f'tags {", ".join(tags)}'
        )
        mids = declared_mod_ids(item)
        if mids:
            print(f"  description Mod IDs: {', '.join(mids)}")
        desc = re.sub(r"\s+", " ", re.sub(r"\[/?[^\]]*\]", " ", item.get("description", "") or ""))
        for m in re.finditer(
            r"[^.]*\b(?:require[sd]?|dependenc\w*|needs?|incompatible|conflict\w*|load (?:after|before))\b[^.]*\.",
            desc,
            re.I,
        ):
            print(f"  - {m.group(0).strip()[:220]}")
        print()
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    root = os.path.abspath(os.path.expanduser(args.dir))
    if root.startswith("/tmp"):
        print(
            "error: steamcmd is bubblewrapped and cannot write under /tmp; "
            "use --dir ~/pzws",
            file=sys.stderr,
        )
        return 2
    os.makedirs(root, exist_ok=True)
    cmd = ["steamcmd", f"+force_install_dir", root, "+login", args.login]
    for iid in args.id:
        cmd += ["+workshop_download_item", APP_ID, iid]
    cmd.append("+quit")
    # cwd must also be under $HOME: bwrap chdir's to the process cwd.
    proc = subprocess.run(cmd, cwd=os.path.expanduser("~"), capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-2000:], file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return proc.returncode

    for iid in args.id:
        base = os.path.join(root, "steamapps/workshop/content", APP_ID, iid)
        print(f"=== {iid}")
        infos = []
        for dirpath, _dirnames, filenames in os.walk(os.path.join(base, "mods")):
            if "mod.info" in filenames:
                infos.append(os.path.join(dirpath, "mod.info"))
        if not infos:
            print(f"  no mod.info under {base} — download failed or item is gated")
            continue
        for path in sorted(infos):
            rel = os.path.relpath(path, os.path.join(base, "mods"))
            print(f"  [{rel}]")
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if re.match(
                        r"^(id|name|require|incompatible|versionMin|loadModAfter|modversion)=",
                        line,
                    ):
                        print("    " + line.rstrip())
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="browse the Workshop for keywords")
    s.add_argument("query", nargs="+")
    s.add_argument("--pages", type=int, default=3, help="browse pages per query (30/page)")
    s.add_argument("--b42", action="store_true", help="keep only Build 42 tagged items")
    s.add_argument("--mp", action="store_true", help="keep only Multiplayer tagged items")
    s.add_argument("--limit", type=int, default=0)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_search)

    d = sub.add_parser("details", help="metadata for specific Workshop ids")
    d.add_argument("id", nargs="+")
    d.add_argument("--json", action="store_true")
    d.set_defaults(func=cmd_details)

    v = sub.add_parser("verify", help="download and print every mod.info")
    v.add_argument("id", nargs="+")
    v.add_argument("--dir", default="~/pzws", help="steamcmd install dir (must be under $HOME)")
    v.add_argument("--login", default="anonymous", help="Steam login for gated items")
    v.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
