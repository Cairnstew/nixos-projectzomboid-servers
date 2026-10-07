#!/usr/bin/env python3
"""pz_steam_workshop.py — print the Steam Workshop content dir of a Project Zomboid install

WHY THIS EXISTS
---------------
The client-host files (`Zomboid/Server/<name>.ini`) are user-level, but the
Workshop CONTENT they refer to lives wherever Steam put it — and where that is
is a property of the machine, not of the pack. Steam records it in
`steamapps/libraryfolders.vdf`, at the Steam root, and the app itself in a
`appmanifest_<appid>.acf` inside one of the libraries it names.

Hard-coding `/mnt/media/SteamLibrary/...` in a host file works until the library
moves, a second library is added, or the machine is not that host. This reads
the answer off disk instead, so "enable the client host" is enough without
anyone writing a path down.

WHY THE APP-MANIFEST AND NOT THE DIRECTORY
-----------------------------------------
A `workshop/content/<appid>` directory can exist, fully populated, and still be
invisible to the game: Project Zomboid's CLIENT enumerates its mods through
Steam's subscription list, not by scanning. The app manifest is the best
on-disk evidence that Steam actually knows about this install — so it is what
decides which library is "the" one, not the presence of content.

EXIT STATUS
-----------
0 and the path on stdout when Project Zomboid is installed via Steam; 1 with no
output otherwise. A missing Steam install is a normal condition (the caller may
be seeding files ahead of the first launch), so it is a status, not an error,
and nothing is written to stderr.

USAGE
-----
    pz_steam_workshop.py [--home DIR] [--appid N] [--steam-root DIR] [--library-root]
"""

import argparse
import os
import re
import sys

# libraryfolders.vdf is Valve's KeyValues format. Only the library paths are
# needed, and a full parser for a format whose grammar includes escaped quotes,
# conditional blocks and `[ ... ]` tuples is not worth carrying: the entries
# wanted are exactly the `"path" "..."` lines.
_PATH_RE = re.compile(r'"path"\s+"((?:[^"\\]|\\.)*)"')


def library_paths(vdf):
    """Yield the library paths named by a libraryfolders.vdf, in file order."""
    with open(vdf, encoding="utf-8", errors="replace") as fh:
        for match in _PATH_RE.finditer(fh.read()):
            # VDF escapes backslashes, so a Windows path arrives doubled.
            yield match.group(1).replace("\\\\", "\\")


def steam_roots(home):
    """Yield the candidate Steam roots, in the order Steam itself prefers."""
    yield from (
        os.path.join(home, ".steam", "steam"),
        os.path.join(home, ".steam", "root"),
        os.path.join(home, ".local", "share", "Steam"),
    )


def find_libraries(home, steam_root=None):
    """Return every library path Steam knows about, the Steam root first.

    The root is included because the default library lives inside it and is not
    always repeated in its own vdf.
    """
    for root in ([steam_root] if steam_root else list(steam_roots(home))):
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        if os.path.isfile(vdf):
            found = [root]
            for path in library_paths(vdf):
                if path not in found:
                    found.append(path)
            return found
    return []


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=os.path.expanduser("~"))
    parser.add_argument("--appid", default="108600")
    parser.add_argument(
        "--steam-root",
        default=None,
        help="Steam root to read instead of probing the usual locations",
    )
    parser.add_argument(
        "--library-root",
        action="store_true",
        help="print the library the app is installed in, not its Workshop dir",
    )
    args = parser.parse_args(argv)

    for library in find_libraries(args.home, args.steam_root):
        manifest = os.path.join(library, "steamapps", f"appmanifest_{args.appid}.acf")
        if os.path.isfile(manifest):
            if args.library_root:
                print(library)
            else:
                print(os.path.join(library, "steamapps", "workshop", "content", args.appid))
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
