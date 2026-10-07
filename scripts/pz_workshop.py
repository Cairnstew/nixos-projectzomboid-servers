#!/usr/bin/env python3
"""pz_workshop.py — Steam Workshop collection <-> modpack catalogue helpers

TWO JOBS, BOTH ABOUT MOVING BETWEEN A COLLECTION AND A PACK
-----------------------------------------------------------
    expand <collection-id>   Read a Steam Workshop COLLECTION and print a draft
                             `modpacks/<name>.nix` reproducing it, order kept.

    emit <pack>              Read the modpack catalogue and print the pack's
                             Workshop items as paste-ready URLs (or a pack
                             skeleton) — the input to Steam's own "add item to
                             collection" UI.

WHY THERE IS NO "PUBLISH A COLLECTION" COMMAND
----------------------------------------------
Steam exposes no public write API for creating or editing Workshop collections;
that lives in the Steam client. So "generate a collection" can only ever mean
EMIT ITS CONTENTS for a human to paste. `emit` is exactly that, and a Steam
collection id is never something a dedicated server consumes anyway: PZ reads
`WorkshopItems=`, a semicolon-separated list of individual item ids.

WHY `expand` PRODUCES A DRAFT, NOT A DONE PACK
----------------------------------------------
A collection carries item ids and titles. It does NOT carry:

  * which items are inert or version-incompatible on your build — that is why
    the committed `viewpoint` pack drops `ZombieBuddy Extensions`;
  * `Mods=` — a comma-separated list of each mod's `mod.info` `id=` value, which
    is not the Workshop id and is only knowable after download;
  * the pack's settings / sandbox.

Those are server-correctness decisions, so `expand` emits a REVIEWABLE draft
with a header saying so, and never writes a file itself. Redirect it:

    nix run .#pz-workshop -- expand 3812346398 > modpacks/owen-oasis.nix

The Steam Web API is public and needs no key. `GetCollectionDetails` returns
child ids and `sortorder`; `GetPublishedFileDetails` returns titles. Both are
called with plain `urllib` so the tool needs nothing but Python.

EXIT STATUS
-----------
0 on success; 1 when the collection or a required input is missing; 2 for a
usage error. Errors go to stderr so stdout stays a pipeable pack.

USAGE
-----
    pz_workshop.py expand <collection-id> [--json] [--appid N] [--name NAME]
    pz_workshop.py emit <pack> [--all] [--format urls|markdown|nix]
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://api.steampowered.com/ISteamRemoteStorage"

# Steam's file_type for a Workshop *collection*, as opposed to an item (0).
FILE_TYPE_COLLECTION = 2

# GetPublishedFileDetails is a batch call; Steam is comfortable with 100 ids.
DETAILS_BATCH = 100

# The catalogue JSON is injected by the flake app wrapper (the same trick as
# `pz-modpack`), because a pack is Nix data and this is not a Nix interpreter.
CATALOGUE_ENV = "PZ_MODPACKS_JSON"


def post(endpoint, params):
    """POST form-encoded params and return the decoded `response` object."""
    body = urllib.parse.urlencode(params, doseq=True).encode()
    req = urllib.request.Request(f"{API}/{endpoint}", data=body)
    with urllib.request.urlopen(req, timeout=30) as fh:
        return json.load(fh).get("response", {})


def collection_children(collection_id):
    """Return [(id, sortorder)] for a collection, in Steam's own order.

    Empty when the collection does not exist or is private — Steam reports both
    as `result: 1` with no children, so the caller must treat "no children" as
    "nothing ingestible" rather than "ok".
    """
    resp = post(
        "GetCollectionDetails/v1/",
        {"collectioncount": 1, "publishedfileids[0]": collection_id},
    )
    details = resp.get("collectiondetails") or []
    if not details:
        return [], None
    detail = details[0]
    if detail.get("result") != 1:
        return [], None
    children = [(c["publishedfileid"], c.get("sortorder", 0)) for c in detail.get("children", [])]
    children.sort(key=lambda pair: (pair[1], pair[0]))
    return [cid for cid, _ in children], detail.get("publishedfileid", collection_id)


def published_details(ids):
    """Return {id: {title, file_type, consumer_app_id, banned}} for the ids.

    Missing / not-found ids come back with `result != 1`; they are preserved in
    the result with `title=None` so the caller can comment them out rather than
    silently drop them (a silently shortened pack is a mod that "does not load"
    for no visible reason).
    """
    out = {}
    for start in range(0, len(ids), DETAILS_BATCH):
        chunk = ids[start : start + DETAILS_BATCH]
        params = {"itemcount": len(chunk)}
        for i, pid in enumerate(chunk):
            params[f"publishedfileids[{i}]"] = pid
        resp = post("GetPublishedFileDetails/v1/", params)
        for item in resp.get("publishedfiledetails", []):
            pid = item.get("publishedfileid")
            if item.get("result") != 1:
                out[pid] = {"title": None, "file_type": None, "consumer_app_id": None, "banned": False}
                continue
            out[pid] = {
                "title": item.get("title"),
                "file_type": item.get("file_type"),
                "consumer_app_id": item.get("consumer_app_id"),
                "banned": bool(item.get("banned")),
            }
    return out


def nix_str(value):
    """Escape a Python string for a Nix double-quoted string.

    `${` MUST be escaped: an unescaped one starts an interpolation and the pack
    fails to evaluate with a baffling error pointing at the mod title.
    """
    if value is None:
        return '""'
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


def render_pack(collection_id, collection_title, items, appid="108600", name=None):
    """Render a reviewable `modpacks/<name>.nix` draft for `items`.

    `items` is a list of (id, title_or_None, note_or_None) in load order.
    """
    pack_name = name or f"workshop-{collection_id}"
    lines = []
    lines.append(f"# modpacks/{pack_name}.nix")
    lines.append("#")
    lines.append(f"# Draft generated by `pz-workshop expand {collection_id}`.")
    lines.append("#")
    lines.append(
        f"# Steam Workshop collection {collection_id}"
        + (f" — {collection_title}" if collection_title else "")
        + f", {len(items)} item(s). Order is the collection's own and is preserved"
        " because it becomes `WorkshopItems=`."
    )
    lines.append("#")
    lines.append("# REVIEW BEFORE COMMITTING — a collection is not a server config:")
    lines.append("#   * drop items inert or version-incompatible on your build;")
    lines.append("#   * `mods` (local mod folder names) cannot be derived from a collection")
    lines.append("#     and stays empty for a Workshop-only pack;")
    lines.append("#   * check `Map=`/settings/sandbox are what you want.")
    lines.append("{")
    lines.append(f"  description = {nix_str(f'Steam Workshop collection {collection_id}')};")
    lines.append("")
    lines.append("  workshopMods = [")
    for item_id, title, note in items:
        if note:
            lines.append(f"    # {note}")
        lines.append(f"    {{ id = {nix_str(item_id)}; title = {nix_str(title)}; }}")
    lines.append("  ];")
    lines.append("")
    lines.append("  mods = [ ];")
    lines.append("")
    lines.append("  defaultSettings = { };")
    lines.append("")
    lines.append("  defaultSandbox = { };")
    lines.append("}")
    return "\n".join(lines) + "\n"


def cmd_expand(args):
    ids, resolved = collection_children(args.collection_id)
    if not ids:
        print(
            f"pz-workshop: collection {args.collection_id} returned no items "
            "(missing, private, or empty)",
            file=sys.stderr,
        )
        return 1

    details = published_details(ids)

    items = []
    for pid in ids:
        d = details.get(pid, {})
        title = d.get("title")
        note = None
        if title is None:
            note = f"NOT FOUND or removed upstream (item {pid}) — verify before use"
        elif d.get("banned"):
            note = f"BANNED on Steam ({pid}) — almost certainly remove"
        elif d.get("consumer_app_id") not in (None, int(args.appid)):
            note = (
                f"consumer_app_id={d['consumer_app_id']} is not Project Zomboid "
                f"({args.appid}) — verify"
            )
        items.append((pid, title, note))

    if args.json:
        print(
            json.dumps(
                {
                    "collection": args.collection_id,
                    "appid": args.appid,
                    "items": [
                        {"id": i, "title": t, "note": n} for i, t, n in items
                    ],
                },
                indent=2,
            )
        )
    else:
        sys.stdout.write(render_pack(args.collection_id, None, items, args.appid, args.name))
    return 0


def load_catalogue():
    path = os.environ.get(CATALOGUE_ENV)
    if not path or not os.path.isfile(path):
        print(
            f"pz-workshop: {CATALOGUE_ENV} is not set to a readable file; "
            "run this through `nix run .#pz-workshop`",
            file=sys.stderr,
        )
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def emit_one(pack, fmt):
    mods = pack.get("workshopMods", [])
    lines = []
    if fmt == "urls":
        for m in mods:
            lines.append(f"https://steamcommunity.com/sharedfiles/filedetails/?id={m['id']}")
    elif fmt == "markdown":
        lines.append(f"### {pack.get('description', '')}".rstrip())
        lines.append("")
        for m in mods:
            title = m.get("title") or "(untitled)"
            lines.append(
                f"- [{title}](https://steamcommunity.com/sharedfiles/filedetails/?id={m['id']})"
            )
    elif fmt == "nix":
        lines.append("  workshopMods = [")
        for m in mods:
            title = m.get("title")
            if title is None:
                lines.append(f'    {{ id = "{m["id"]}"; }}')
            else:
                lines.append(f'    {{ id = "{m["id"]}"; title = {nix_str(title)}; }}')
        lines.append("  ];")
    return lines


def cmd_emit(args):
    catalogue = load_catalogue()
    if catalogue is None:
        return 1

    if args.all:
        packs = sorted(catalogue)
    else:
        if args.pack not in catalogue:
            print(
                f"pz-workshop: no such modpack: {args.pack}. "
                f"Available: {', '.join(sorted(catalogue))}",
                file=sys.stderr,
            )
            return 1
        packs = [args.pack]

    blocks = []
    for name in packs:
        pack = catalogue[name]
        mods = pack.get("workshopMods", [])
        header = f"# {name} — {len(mods)} Workshop item(s)"
        block = [header] + emit_one(pack, args.format)
        blocks.append("\n".join(block))

    sys.stdout.write("\n\n".join(blocks) + "\n")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pz-workshop",
        description="Steam Workshop collection <-> modpack catalogue helpers.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    expand = sub.add_parser(
        "expand",
        help="read a Steam Workshop collection and print a draft modpack .nix",
    )
    expand.add_argument("collection_id", help="Steam Workshop collection id (digits)")
    expand.add_argument("--appid", default="108600", help="Project Zomboid app id (default: 108600)")
    expand.add_argument("--name", default=None, help="pack name for the file header")
    expand.add_argument("--json", action="store_true", help="emit JSON instead of Nix")
    expand.set_defaults(func=cmd_expand)

    emit = sub.add_parser(
        "emit",
        help="print a catalogue pack's Workshop items as a paste-ready list",
    )
    emit.add_argument("pack", nargs="?", help="modpack name (omit with --all)")
    emit.add_argument("--all", action="store_true", help="every pack in the catalogue")
    emit.add_argument(
        "--format",
        choices=["urls", "markdown", "nix"],
        default="urls",
        help="output shape (default: urls)",
    )
    emit.set_defaults(func=cmd_emit)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
