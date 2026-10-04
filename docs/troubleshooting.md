# Troubleshooting

Real failures, in roughly the order you are likely to hit them.

For "my mod's map is not loading" specifically, jump to
[Map problems](#map-problems) — that has its own section because it is the most
confusing symptom in this project.

---

## Evaluation fails — nothing gets built

### `expected a set but found a function`

```
error: expected a set but found a function: «lambda @ …/default.nix:37:1»
```

You are selecting an attribute off a `fetchTarball` import whose top level is a
function. Fixed in `default.nix` — see [CHANGELOG](../CHANGELOG.md). If you are
on an older revision, either upgrade or import the module file directly:

```nix
imports = [ (import (builtins.fetchTarball { url = "…"; })) + "/modules/project-zomboid-servers.nix" ];
services.project-zomboid-servers.package = pkgs.callPackage … ;  # you now supply this
```

The shape is: `default.nix` must evaluate to an **attrset** for
`(import (fetchTarball …)).nixosModules.default` to be expressible at all.

### `The option 'services.project-zomboid-servers.web.enable' … is already declared`

```
The option `services.project-zomboid-servers.web.enable' in
`…-source/modules/options.nix' is already declared in
`/home/you/repo/modules/options.nix'.
```

You are consuming this project **twice** on one host — once as a flake input and
once via `fetchTarball`, or via two different checkouts. NixOS sees two
`_file`s declaring the same options and refuses.

Pick one source per host. See [Do not mix sources](installing.md#do-not-mix-sources).

### `Your system configures nixpkgs with an externally created instance`

You set both `nixpkgs.config.allowUnfree` and `nixpkgs.pkgs`. NixOS accepts one
or the other:

```nix
# Either
nixpkgs.config.allowUnfree = true;

# …or
nixpkgs.pkgs = import nixpkgs { system = "…"; config.allowUnfree = true; };
```

### `services.project-zomboid-servers.package is null`

Import through an entry point that fills `package` in — see
[installing](installing.md). The bare module file cannot name its own package,
because a flake input's module scope has no path back to its flake.

If you hit this on a revision where you get
`lib.meta.getExe': The first argument is of type null` instead, the module's own
assertion was being masked by a crash inside unit generation. Both were fixed
together.

### `i686 Linux package set can only be used with the x86 family`

PZ has no ARM Linux build, so `steamcmd`/`steam-run` cannot be instantiated on
`aarch64-linux`. `systems` is restricted to `x86_64-linux` for this reason.

The module *evaluates* on ARM; `package` will not build there. Run the server
elsewhere, or build x86_64 under emulation.

### `attribute 'project-zomboid-server' missing`

A non-flake consumer passed their own `nixpkgs.pkgs` while the module was using a
package set built from `<nixpkgs>`. `default.nix` now derives the launcher with
`pkgs.callPackage` on **your** package set, so this cannot happen; upgrade if you
are on an older revision.

### `nix fmt` fails with `<stdin>: unexpected end of input`

```
error: … <stdin>:1:19: error: unexpected end of input / expecting expression
```

`pkgs.nixfmt-rfc-style` is deprecated in current nixpkgs and broken there. This is
upstream, not this repo, and it fails on an untouched checkout too.

Run the formatter per file instead:

```bash
nix eval --raw .#formatter.x86_64-linux.outPath
# then: $FMT -- path/to/file.nix   for each file
```

The proper replacement is `pkgs.nixfmt-tree` (treefmt), which uses a different
invocation model.

---

## The server will not start

### `Assertion Failed: Illegal termination of worker thread`

`steam_appid.txt` contained two or more app ids. It must contain exactly one
line, and it must be the **join** app id `108600` — not the dedicated-server id
`380870`.

The launcher overwrites it on every start, so a stale multi-id file cannot
accumulate through this module. If you are hitting this, something else is
writing it.

### Clients cannot join, server logs a Lua checksum error

Set `DoLuaChecksum = false`. Build 42 has a Linux false-positive bug in Lua
checksum validation that blocks clients from joining. Both bundled packs set it.

### It will not come back after a clean stop

`restart = "on-failure"` is wrong for PZ. Stopping cleanly sends `quit` down the
console, which makes the JVM exit `0` — a *success*, so the unit stays down. The
default here is `always`. Use `on-failure` only if you want a crash-looping
server to stay down.

### `cp: cannot create regular file: Permission denied`

A store file is mode `444`, and `cp` gives the destination the source's
permissions — so the **second** start could not overwrite it. `install -m 0644`
unlinks first and is correct regardless of the current mode. Fixed; upgrade if
you are on an older revision.

In production PZ rewrites `_SandboxVars.lua` in between and masks this, which is
why it survived so long.

### `arg '' has no '='`

An optional argument reached `merge_ini.py` as a single empty string, so it
tried to parse a key that did not exist. Two distinct causes, both fixed:

- `${v+$v}` expands whenever `v` is merely **set** — and `v=""` is set.
- `"${v:+$v}"` passes one **empty** argument, because a quoted expansion is
  always exactly one word that never disappears.

The correct bash spelling is `${v:+"$v"}` — quotes on the *inner* value only.

### First start times out or looks hung

The first `ExecStartPre` downloads the whole dedicated server and every Workshop
mod in the pack. `project-zomboid-install.service` has `TimeoutStartSec = "45min"`
for that reason. Subsequent starts are a fast `validate`.

To skip the validate entirely — for a config-only change, or a test — use
`--no-install` under `nix run`, or set `updateOnStart = false`.

### `steam-run` / FHS errors, or a sandbox directive breaks the unit

The unit runs under `steam-run`, which uses user-namespace/bwrap. Avoid
`extraServiceConfig` directives that sandbox harder than that, or the FHS
environment the server binary expects will not come up.

---

## Map problems

### A mod's map is not showing up, or the wrong tiles load

Diagnose first:

```bash
nix run .#pz-maps -- --workshop-root <serverDir>/steamapps/workshop/content/108600 --explain
# or, against a server dir:
nix run .#pz-dedicated-server -- --list-maps
```

`--explain` prints which mod each map came from and its sort rank. Then:

1. **Duplicate map names.** `pz-maps: warning: map 'West Point, KY' is shipped by
   2 mods`. PZ resolves `media/maps/<name>` across *every* loaded mod, so the
   winner is whichever the loader reaches first — which depends on download
   order. That is non-deterministic and silent: the server starts fine and the
   wrong tiles load. Fix it deterministically:

   ```nix
   mapOrder = {
     priority = [ "2705410157" ];   # this mod wins, and orders first
     strict = true;                 # refuse to start on any future clash
   };
   ```

   `dedupe = true` renames the losers to `*.pz-duplicate`, but it **writes to the
   shared install**, which every server on it reads — hence off by default.
   Renaming rather than deleting keeps it recoverable.

2. **A directory that is not a map.** Only a directory containing `map_*.lotpack`
   counts. `pz_maps.py` ignores anything else, so a mod shipping
   `media/maps/JustDocs/README.md` does not create a map.

3. **Base-map shadowing.** A mod shipping a folder named exactly `baseMap`
   shadows vanilla terrain. That is reported as an **error**, deliberately.

### `Map=` is empty

Either no installed mod ships a map, or detection is off. Check with
`--list-maps`. If you set `map` explicitly, detection is suppressed entirely and
the pinned value wins outright.

Also: the map list is **semicolon** separated, while `Mods=` is **comma**
separated. Both are `WorkshopItems=`-adjacent keys, and swapping them is silent.

---

## Config and world state

### The world renumbers on every start

`Seed`, `ResetID`, `LastModified` and `ServerPlayerID` live in the *same* `.ini`
the module writes config into. Writing that file from scratch destroys the world
identity.

`merge_ini.py` only ever updates the keys the module owns and leaves every other
line alone — and the `prep-roundtrip` check asserts those four keys survive,
because this is the single most destructive thing that could go wrong.

If you are seeing it, something else is writing the file.

### `SandboxVars.lua` is a syntax error

Profession keys that are not valid Lua identifiers must be bracket-quoted. Two
bugs got through here once, both invisible to `grep`:

- consecutive table entries joined by a newline instead of a comma — `}` then `{`
  is not valid Lua;
- a quoted profession used as a key, `"farm worker" = {`, which Lua reads as a
  positional value and then finds `=` where it expects `,` or `}`.

The `spawn-and-reset` check now parses every generated Lua file with a real Lua
interpreter. Upgrade if you are on an older revision.

### A local (modworkshop.net) mod is ignored

Two usual causes:

- **Wrong directory.** It belongs in the *server's own* home, not the shared
  install: `<dataDir>/<servername>/Zomboid/mods/<ModFolder>/`.
- **No `mod.info`.** PZ decides what is a mod by that file. And because it ships
  with CRLF line endings, validating with a shell `grep` needs
  `grep -llx -E "id=$mod[[:cntrl:]]?"`.

`mods` takes the `id=` value from `mod.info`, not the folder name — they are
often but not always the same.

### `Whitelist=` / `Users=` do nothing

Correct, and deliberate: they are not documented Build 42 ini keys. On Build 42
the whitelist is a table in `Zomboid/db/<servername>.db`.

- To actually create an admin account, use `adminAccount`.
- To write the Build 41 keys anyway, set `compatibility.build41 = true`.

---

## Checks and CI

### A check fails with `expected a list but found a string`

Fixed. `module-eval` built its assertion-failure list with
`lib.concatMap` over `lib.optionalString`, which returns a **string**; `concatMap`
is `concat . map` and `concat` wants a list. With zero failures `concat [ ]` never
trips, so the bug only appeared on the day something actually broke — replacing
the readable message with a type error.

### A check fails vacuously

`module-eval` asserts that the module contributed at least one assertion, and
fails loudly otherwise. If you see that, `modules/config.nix` is probably no
longer imported.

---

## Getting more detail

```bash
journalctl -u project-zomboid-main -f          # the server's own output
systemctl cat project-zomboid-main              # the generated unit
systemctl show project-zomboid-main -p ExecStartPre

nix run .#pz-vanilla-plus -- --data-dir ./d --no-install --print-config myserver
```

That last one needs no game files, no network and no systemd, so it is the
fastest way to see what a configuration actually renders to.