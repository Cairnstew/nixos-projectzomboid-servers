#!/usr/bin/env python3
"""pz_maps.py — deterministic Project Zomboid map discovery and ordering

WHY THIS EXISTS
---------------
A PZ server's `Map=` key is a SEMICOLON-separated list, and it is the one piece
of server configuration that cannot be written down statically and be correct.
Maps live inside mods: a mod that ships `media/maps/Nash County, KY` only takes
effect if that name is in `Map=`. So every mod that adds a map has to be
reflected in the config, and the moment one is added or removed by hand the
config drifts from the mod list.

Two things make that worse than it needs to be:

1.  Nothing enforces an ORDER, but the order is load-bearing. PZ resolves
    `media/maps/<name>` across every loaded mod, so if two mods ship the same
    map name the winner is whichever the mod loader happens to reach first —
    which depends on `Mods=`/`WorkshopItems=` order, and therefore on whichever
    mod id the platform returned first. Non-deterministic, and silently so: the
    server starts fine and the wrong tiles load.

2.  The community's answer to this is manual. The most popular server-config
    editor for the game (Workshop item 2725216703, "Mod Manager: Server", ~1.4M
    subscribers) explicitly documents that it does NOT manage maps or spawn
    regions: "If you add or remove mods containing maps and/or spawn regions,
    you have to edit the Map and/or Spawn Regions sections of your server
    config manually."

WHAT THIS DOES
--------------
Scans the installed mods, derives the map set, and orders it by a TOTAL sort
key — so the same inputs always produce the same `Map=`, on any machine, in any
directory-iteration order. Collisions are reported rather than silently
resolved, because silently picking a winner is how you get a world built on the
wrong tiles.

ORDERING RULE (the whole contract, in one place)
------------------------------------------------
1. Mod maps first, ordered by
       (priority rank, kind, numeric id, mod id, map name)
   where `priority rank` is the index in `--priority` (unlisted = last) and
   `kind` puts Workshop before local. Every component is a stable comparison —
   nothing depends on how the filesystem happened to list a directory.
2. The base map LAST, always. Mod maps add new areas; they do not patch vanilla
   tiles. Putting vanilla last means any genuine overlap resolves in favour of
   the base map, which is the safe direction.

COLLISIONS
----------
Two mods shipping the same map name is the conflict case. The winner is chosen
by the same sort key (so it is deterministic), and the losers are reported. A
collision with the BASE map is called out separately and more loudly, because a
mod shadowing a vanilla map replaces terrain that players already know.

`--strict` turns any collision into a non-zero exit, for callers that would
rather refuse to start than guess. `--dedupe` additionally renames the losing
folders out of the way; it is OFF by default because it writes to the shared
Steam install, which other servers may be using.

USAGE
-----
    pz_maps.py --workshop-root DIR [--local-mods DIR] [--base-map NAME]
               [--priority ID ...] [--strict] [--dedupe]
               [--format map|list|json] [--explain]

    --format map     the `Map=` value            (default)
    --format list    the same names, one per line
    --format json    machines-readable: sources, order, collisions, map value
    --explain        print the reasoning (stderr) alongside any format
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from dataclasses import dataclass, field

# A directory under `media/maps/` only counts as a map if it holds PZ map data.
# Without this, stray files (README.md, .gitkeep, a `maps.json`) become phantom
# map names and land in `Map=`, which the game rejects.
MAP_SUFFIXES = (".lotpack", ".lotheader")

# Renamed-into place when --dedupe neutralises a loser. Reversible by hand.
DEDUPE_SUFFIX = ".pz-duplicate"


@dataclass(frozen=True)
class Source:
    """One mod that may ship maps."""

    kind: str  # "workshop" | "local"
    mod_id: str  # workshop id, or local folder name
    root: str  # the mod's own directory

    @property
    def rank_id(self) -> int:
        """Numeric form of the id for ordering. Non-numeric ids sort as 0."""
        return int(self.mod_id) if self.mod_id.isdigit() else 0


@dataclass(frozen=True)
class MapEntry:
    """One map name found in one mod."""

    name: str
    source: Source
    path: str  # .../media/maps/<name>


@dataclass
class Collision:
    """One map name provided by more than one mod."""

    name: str
    winner: MapEntry
    losers: list[MapEntry] = field(default_factory=list)
    shadows_base: bool = False

    def label(self, entry: MapEntry) -> str:
        return f"{entry.source.kind} mod {entry.source.mod_id}"


def sort_key(entry: MapEntry, priority: dict[str, int]) -> tuple[int, int, int, str, str]:
    """A TOTAL ordering over map entries.

    Every element is a stable comparison of data we control, so this is
    independent of directory iteration order. `priority` is the user's
    `--priority` list; unlisted mods get a large rank so they sort last.
    """
    s = entry.source
    return (
        priority.get(s.mod_id, len(priority)),
        0 if s.kind == "workshop" else 1,
        s.rank_id,
        s.mod_id,
        entry.name,
    )


def looks_like_map(path: str) -> bool:
    """True if `path` contains PZ map data rather than stray files."""
    try:
        with os.scandir(path) as it:
            for item in it:
                if item.is_file() and item.name.endswith(MAP_SUFFIXES):
                    return True
                if item.is_file() and item.name == "spawnpoints.lua":
                    return True
    except OSError:
        return False
    return False


def sources_from_workshop(root: str) -> list[Source]:
    """`root` is .../workshop/content/108600; each numeric child is a mod."""
    out: list[Source] = []
    if not os.path.isdir(root):
        return out
    with os.scandir(root) as it:
        for item in it:
            if item.is_dir() and item.name.isdigit():
                out.append(Source("workshop", item.name, item.path))
    return out


def sources_from_local(root: str) -> list[Source]:
    """`root` is a mods directory; each child is a mod folder."""
    out: list[Source] = []
    if not os.path.isdir(root):
        return out
    with os.scandir(root) as it:
        for item in it:
            if not item.is_dir():
                continue
            # Skip symlinks back into the shared install's own dirs; a
            # self-referential mod dir would otherwise be scanned twice.
            if os.path.islink(item.path) and os.path.realpath(item.path).startswith(
                os.path.realpath(root) + os.sep + ".."
            ):
                continue
            out.append(Source("local", item.name, item.path))
    return out


def discover(sources: list[Source]) -> list[MapEntry]:
    """Every map each source ships."""
    out: list[MapEntry] = []
    for src in sources:
        maps_dir = os.path.join(src.root, "media", "maps")
        if not os.path.isdir(maps_dir):
            continue
        with os.scandir(maps_dir) as it:
            for item in it:
                # Skip already-deduped folders so a second run is a no-op.
                if not item.is_dir() or item.name.endswith(DEDUPE_SUFFIX):
                    continue
                if not looks_like_map(item.path):
                    continue
                out.append(MapEntry(item.name, src, item.path))
    return out


def resolve(
    entries: list[MapEntry],
    base_map: str | None,
    priority: dict[str, int],
) -> tuple[list[str], list[Collision], list[str]]:
    """Order the map names and report every collision.

    Returns `(ordered_names, collisions, reasons)` where `reasons` is one human
    line per ordering decision, for `--explain`.
    """
    by_name: dict[str, list[MapEntry]] = {}
    for e in entries:
        by_name.setdefault(e.name, []).append(e)

    collisions: list[Collision] = []
    winners: list[MapEntry] = []

    for name in sorted(by_name):
        group = sorted(by_name[name], key=lambda e: sort_key(e, priority))
        win, rest = group[0], group[1:]
        winners.append(win)
        if rest:
            collisions.append(
                Collision(
                    name=name,
                    winner=win,
                    losers=rest,
                    shadows_base=base_map is not None and name == base_map,
                )
            )
        elif base_map is not None and name == base_map:
            # A single mod ships a map named exactly like the base map. No mod
            # conflict here, but the mod's tiles shadow vanilla terrain that
            # players already know, so it is reported with the same urgency as
            # a real collision.
            collisions.append(
                Collision(name=name, winner=win, losers=[], shadows_base=True)
            )

    winners.sort(key=lambda e: sort_key(e, priority))

    reasons: list[str] = []
    for e in winners:
        why = f"priority {priority[e.source.mod_id]}" if e.source.mod_id in priority else "no priority"
        reasons.append(
            f"  {e.name}: from {e.source.kind} mod {e.source.mod_id} ({why}, rank {sort_key(e, priority)})"
        )

    ordered = [e.name for e in winners]

    # The base map goes last, and is added even if no mod ships it — that is the
    # normal case, and it is what makes the server playable at all.
    if base_map:
        if base_map in ordered:
            # A mod ships a map named like the base map. It wins the slot (it
            # is first), but the base map must still be the last entry.
            ordered = [n for n in ordered if n != base_map] + [base_map]
        else:
            ordered = ordered + [base_map]
        reasons.append(f"  {base_map}: base map, always ordered last")

    return ordered, collisions, reasons


def apply_dedupe(collisions: list[Collision]) -> list[str]:
    """Rename each losing map folder so it is inert. Returns what was renamed.

    Destructive, therefore opt-in: the folders are inside the shared Steam
    install, which every server on this install reads. Renaming (rather than
    deleting) keeps the data recoverable.
    """
    renamed: list[str] = []
    for c in collisions:
        for loser in c.losers:
            target = f"{loser.path}{DEDUPE_SUFFIX}"
            if os.path.exists(target):
                continue
            shutil.move(loser.path, target)
            renamed.append(f"{loser.path} -> {target}")
    return renamed


def report(collisions: list[Collision]) -> None:
    for c in collisions:
        if c.shadows_base:
            # Base-map shadowing reads very differently from a mod-vs-mod clash:
            # there is no second mod, just a mod replacing vanilla terrain.
            print(
                f"pz-maps: ERROR: mod {c.winner.source.mod_id} ships a map named "
                f"'{c.name}', which is also the base map",
                file=sys.stderr,
            )
            print(
                f"  its tiles shadow vanilla terrain — players will find changed "
                f"ground where '{c.name}' used to be",
                file=sys.stderr,
            )
            print(
                "  pin the map explicitly (map = \"...\"; mapOrder.enable = false) "
                "to silence this, or accept it deliberately",
                file=sys.stderr,
            )
            continue
        print(
            f"pz-maps: warning: map '{c.name}' is shipped by {len(c.losers) + 1} mods",
            file=sys.stderr,
        )
        print(f"  using: {c.label(c.winner)}", file=sys.stderr)
        for loser in c.losers:
            print(f"  ignored: {c.label(loser)}", file=sys.stderr)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="pz-maps",
        description="Deterministic Project Zomboid map discovery and ordering.",
    )
    p.add_argument(
        "--workshop-root",
        action="append",
        default=[],
        metavar="DIR",
        help="a .../workshop/content/108600 directory; repeatable",
    )
    p.add_argument(
        "--local-mods",
        action="append",
        default=[],
        metavar="DIR",
        help="a mods directory whose children are mod folders; repeatable",
    )
    p.add_argument("--base-map", default=None, metavar="NAME", help="ordered last, always")
    p.add_argument(
        "--priority",
        action="append",
        default=[],
        metavar="ID",
        help="mod id that wins collisions and orders first; repeatable, in order",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero if any collision was found",
    )
    p.add_argument(
        "--dedupe",
        action="store_true",
        help="rename losing duplicate map folders out of the way (writes to the install)",
    )
    p.add_argument(
        "--format",
        choices=("map", "list", "json"),
        default="map",
        help="output format (default: map)",
    )
    p.add_argument("--explain", action="store_true", help="explain the ordering on stderr")
    args = p.parse_args(argv)

    sources: list[Source] = []
    for root in args.workshop_root:
        sources.extend(sources_from_workshop(root))
    for root in args.local_mods:
        sources.extend(sources_from_local(root))

    priority = {mid: i for i, mid in enumerate(args.priority)}

    entries = discover(sources)
    ordered, collisions, reasons = resolve(entries, args.base_map, priority)

    renamed: list[str] = []
    if args.dedupe and collisions:
        renamed = apply_dedupe(collisions)
        if renamed:
            print("pz-maps: deduped (rename the folders back to undo):", file=sys.stderr)
            for r in renamed:
                print(f"  {r}", file=sys.stderr)

    if collisions:
        report(collisions)
    if args.explain and reasons:
        print("pz-maps: ordering:", file=sys.stderr)
        for r in reasons:
            print(r, file=sys.stderr)

    if not ordered:
        print("pz-maps: no maps found", file=sys.stderr)
        # Not an error: a modpack of pure QoL mods ships no maps, and the caller
        # may not have set --base-map. The caller decides what an empty Map means.
        if args.format != "json":
            return 0

    if args.format == "json":
        print(
            json.dumps(
                {
                    "map": ";".join(ordered),
                    "order": ordered,
                    "sources": [
                        {
                            "map": e.name,
                            "kind": e.source.kind,
                            "mod_id": e.source.mod_id,
                            "path": e.path,
                        }
                        for e in sorted(entries, key=lambda e: (e.name, sort_key(e, priority)))
                    ],
                    "collisions": [
                        {
                            "map": c.name,
                            "winner": c.winner.source.mod_id,
                            "losers": [x.source.mod_id for x in c.losers],
                            "shadows_base": c.shadows_base,
                        }
                        for c in collisions
                    ],
                    "deduped": renamed,
                },
                indent=2,
                sort_keys=True,
            )
        )
    elif args.format == "list":
        for name in ordered:
            print(name)
    else:
        print(";".join(ordered))

    return 1 if (args.strict and collisions) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))