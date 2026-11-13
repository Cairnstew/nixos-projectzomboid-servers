# Plan: a "pack web" for each modpack

> Status: **Phase 0 implemented** (2026-11-13). This document is the report the
> investigation produced, plus the design that follows from it. It deliberately
> rejects the original framing ("one custom mod per pack that does everything")
> and splits the goal into four layers.
>
> Phase 0 landed as: `sandboxNamespaces` (`lib/default.nix`,
> `modules/options/servers.nix`), the `vanilla-plus` repair (six verified Build 42
> pairs), the catalogue guard (`checks/default.nix`), and `pz-pack-doctor`
> (`scripts/pz_pack_doctor.py` + the flake app + `pack-doctor` check). Phase 1
> (the opt-in overlay) remains a proposal.

## 1. The question

Could each modpack ship a custom-defined mod that acts as a single place to:

1. patch other mods;
2. hard-configure mod options (and other settings);
3. declare the requirements of every mod in the pack — a "web" that completes
   the pack;
4. ensure client-side and server-side mods are available.

The short answer: the **goal is good**, the **single mod is the wrong tool for
three of the four**. Each job belongs to a different layer:

| Job | Layer | Custom mod? |
| --- | --- | --- |
| 1. Patch another mod's files | a load-last overlay mod | **Yes** — opt-in, per pack |
| 2. Hard-configure mod options | `sandbox` / `.ini` in Nix | **No** — close one renderer gap |
| 3. Declare the dependency web | tooling + catalogue data | **No** — `require=`-all is a trap |
| 4. Client/server availability | `WorkshopItems=` + Steam | **No** — a mod cannot do it |

## 2. What the game actually permits

Verified against the PZ wiki and the PZ API docs (`mod.info`, `Load order`,
`Mod structure`, `Sandbox options`), not against assumptions:

- **File patching is real.** A file under `media/lua/...` or `media/scripts/...`
  is overwritten by a later-loaded mod's file at the **same path relative to
  `media/`** (`Load order § File overwrites`).
- **Order can be declared.** `mod.info` parses `require=`, `loadModAfter=`,
  `loadModBefore=` and `incompatible=`. `loadModAfter` orders without creating a
  hard dependency; it is the right primitive for a patch mod.
- **B42 places `mod.info` in a version folder** (`42/`), or `common/`, never the
  mod root. `common/` and version folders do **not** participate in cross-mod
  overwrites, so patch files must live in `42/media/...`.
- **Mod options are sandbox options.** A mod ships `media/sandbox-options.txt`
  declaring `option Namespace.Option`, read as `SandboxVars.Namespace.Option`.
  The values live in `<server>_SandboxVars.lua`, a file this module owns.
- **There is no client-only / server-only mod flag.** The split is
  `media/lua/{shared,client,server}` plus runtime `isClient()` / `isServer()`.
- **Only the Workshop delivers mods to clients.** PZ's join check compares the
  enabled mod list and Steam supplies Workshop items. A non-Workshop folder is
  never pushed to clients — see `docs/mod-delivery.md` §"Why the client cannot
  load from the server's directory" and `modules/home.nix` on `installMods`.

## 3. Goal-by-goal

### 3.1 Hard-configuring mod options — do it in Nix, not a mod

`renderSandbox` already renders nested tables, but it rejects **every** table it
does not know. A mod namespace (`Bandits.Enabled`, `TrueActions.Something`) is
unrepresentable today:

```console
$ nix eval ... 'f.lib.renderSandbox { settings = { "Bandits.Enabled" = true; }; }'
error: project-zomboid-servers: invalid nested SandboxVars key(s):
  - Bandits.Enabled
Use `Table.Key`, where Table is one of:
Basement, Map, MultiplierConfig, ZombieConfig, ZombieLore.
```

The guard is `dottedProblem` (`lib/default.nix:350-363`) against the hard-coded
`nestedSandboxTables` (`lib/default.nix:163`). The fix is an allow-list of mod
namespaces, keeping the typo protection for everything else:

```nix
sandboxNamespaces = [ "Bandits" "TrueActions" ];

sandbox."Bandits.Enabled" = true;
```

That is a small renderer change plus one option. No mod, no client delivery, no
licensing question, no checksum change.

The honest limit: sandbox values are baked at world creation for many options,
and mods that keep settings in their own cfg/ModData are **not** declaratively
settable. A patch mod cannot reliably pre-seed those either. So "mod options"
works through the sandbox channel; the rest stays case-by-case.

### 3.2 A single source of patching — a real mod, but only the last mile

Mechanically sound: one generated mod per pack, loaded last, containing only the
glue nobody publishes. It must be **generated from `pack.mods`** so the pack
stays the single source and the mod cannot drift into a second hand-maintained
list.

Costs that make it a bad default:

- **Licensing.** An override file is a derived copy of another author's code; the
  wiki's `Modpack` page notes repacking is discouraged and needs permission.
  Runtime hooks avoid this; wholesale overrides do not.
- **Maintenance.** Every upstream update can invalidate a patch, and the patched
  file now misattributes bugs to the upstream author.
- **Delivery.** A local overlay must also be installed on every client. On a
  public server that means publishing your own Workshop item. Otherwise it is
  `localMods` plus `DoLuaChecksum=false` — already the case in both bundled
  packs (`modpacks/viewpoint.nix:1505`) but not for consumers.
- **Silent no-ops.** If the target renames its file, the override becomes dead
  code that still loads. A post-download check is mandatory.

Verdict: an **opt-in per-pack escape hatch**, never "default for every pack".
The existing third-party fixes in `viewpoint` (`HorsePatch3d`, `ViewpointHeli`,
`ViewpointBloodFXAddon`, the VFE patches) should stay upstream mods; replacing
them with our copies is strictly worse.

### 3.3 The dependency web — build the graph, do not encode it as `require=`

A `require=` line listing all ~480 ids in `viewpoint` looks like a web but
behaves badly:

- `require=` is a **hard** dependency. One missing or mature-gated item makes PZ
  skip the overlay — the patches and diagnostics vanish exactly when they are
  needed most.
- It does not fetch anything. It only orders and fails.
- On a dedicated server an unmet dependency is skipped, not fatal.

Use `loadModAfter` for ordering (soft), and `require` only for the specific mods
a patch genuinely cannot run without.

The authoritative graph only exists after download, inside each `mod.info`. The
repo already parses that: `scripts/pz_workshop.py` reads the Workshop description
for `Mod ID:`, and `scripts/pz_client_mods.py:141-160` walks mod roots and reads
`id=`. The web therefore belongs in a **post-download validator**, not a mod.

**This is not hypothetical.** Evaluating the catalogue gives:

```console
viewpoint      workshop=438  mods=480
vanilla-plus   workshop=6    mods=0
```

`vanilla-plus` declares six Workshop items and **zero Mod IDs**, so `Mods=`
renders empty (`lib/default.nix:792`): the install downloads six items and the
server loads none. The catalogue check (`checks/default.nix:576-606`) validates
shape only, and the client-host check that asserts `Mods=` is non-empty uses
`viewpoint` (`checks/default.nix:1279-1321`). It has been that way since the
initial commit. A validator — not a runtime mod — is what would have caught it.

### 3.4 Client/server availability — not solvable by a mod

There is no such flag in `mod.info`, both sides must match the mod list, and
clients only get content from Steam. The levers are the ones the repo already
has: a complete `WorkshopItems=`, a Steam collection for one-click subscription
(`pz-workshop emit`), the client preset (`clientHost.preset`) so the client
actually enables the pack, and `localMods` for the exceptions. What is missing is
**reporting** — classify installed mods by their Lua folders and warn about
asymmetry — not enforcement.

## 4. Design

### Phase 0 — no mod (do now)

- [x] **Mod sandbox namespaces.** `renderSandbox` takes `namespaces`; a server
      option `sandboxNamespaces` (and the same key in a pack) allows
      `Table.Key` for those tables while keeping the typo guard. Option, check,
      docs.
- [x] **Fix `vanilla-plus`.** It currently downloads six Workshop items and
      loads none. Resolve the real Mod IDs and list them.
- [x] **Catalogue check.** Reject `workshopMods != []` with `mods == []` unless
      the pack opts out explicitly, and reject duplicate Workshop ids / Mod IDs.
- [x] **`pz-pack-doctor` app.** Run against an installed Workshop root and the
      catalogue: map each item to its `mod.info` id(s), verify every `mods` entry
      has a provider, every `require=`/`loadModAfter=` target is in the pack,
      `incompatible=` pairs are both present, `Mods=` is not empty while
      `WorkshopItems=` is, and classify client/server/shared Lua. Warn by
      default; exit non-zero in `--strict`. A check exercises it against a
      synthetic workshop tree.

### Phase 1 — opt-in overlay (only when a concrete pain needs it)

- [ ] `packOverlay` as **pack data** (`patches` = relative path -> text/source,
      `loadAfter`, `require`, `modInfoExtra`). Packs stay pkgs-free
      (`modpacks/default.nix:35` imports them with no arguments).
- [ ] The module materialises `42/mod.info` + `42/media/...` into a store path
      and adds it to `localMods` (which already symlinks into `Zomboid/mods` and
      appends to `Mods=` — `modules/options/servers.nix:89`,
      `lib/prepare.nix:311-330`).
- [ ] Checks: every patch path starts `42/media/`; every `source` exists; the id
      does not collide with a pack mod; the doctor verifies post-download that
      each overridden relative path exists in its target (otherwise it is a
      silent no-op).
- [ ] Default **off**. Never generated for a pack that has not asked for it.

### Phase 2 — publish, only if a public server needs the overlay

Publishing our own Workshop item is a deliberate decision (Steam account, upload
flow, an item we then own), not a side effect. Until then, an overlay is a
private-server tool.

## 5. Rejected alternatives

- **Patch files into the downloaded workshop directory.** `steamcmd validate`
  reverts it, `prune` deletes it, clients never see it, and it makes the next
  pack switch unprunable. Rejected.
- **`require=` every pack mod on a manifest mod.** Turns one missing mod into a
  silently skipped mod, and adds nothing the server's own `Mods=` miss does not
  already report. Use `loadModAfter` for order and the doctor for validation.
- **A default manifest mod.** Its only unique value is runtime introspection;
  the pre-flight doctor answers the same questions with no delivery risk.

## 6. Risks

| Risk | Mitigation |
| --- | --- |
| Patches rot on an upstream update | Doctor verifies target paths post-download; keep patches tiny |
| Overrides redistribute another author's code | Prefer event hooks; document permission per patch |
| Local overlay blocks public joins | Publish to Workshop (Phase 2) or keep it private |
| `DoLuaChecksum` drift | Already `false` in both packs; document for consumers |
| A namespace typo becomes a silent no-op | Only declared namespaces are allowed; undeclared tables still throw |
| Catalogue becomes a second source | Overlay is generated from `pack.mods`, never hand-listed |
