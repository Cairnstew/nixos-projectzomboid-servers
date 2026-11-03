---
name: pz-mod-search
description: Use when searching Steam Workshop for new Project Zomboid mods to add to a modpack, vetting Build 42 and multiplayer compatibility, resolving a Workshop id to its real Mod ID(s), checking hidden dependencies/conflicts, or deciding whether a candidate duplicates a mod already in modpacks/<pack>.nix.
---

# Finding & Vetting Project Zomboid Mods

`nix run .#pz-workshop` handles **collections and existing packs** (`expand`,
`resolve`, `emit`). This skill is the other half: **discovery** — keyword
search, compatibility vetting, and turning a Workshop id into a safe pack
entry. The bundled helper is `scripts/pz-workshop-search.py` (stdlib only).

Server app is **380870**; Workshop items are for game app **108600**.

## The one rule

> A Workshop item is not a mod.

One item can ship several mods: balance tiers, per-vehicle-pack addons, an
uninstall mod, a safe-removal mod. Descriptions routinely omit required
dependencies. **Read `mod.info` before writing a pack entry** — that is the only
authority for `Mods=`, `require=` and `incompatible=`.

## 1. Search

Browse URL (no key, HTML):

```
https://steamcommunity.com/workshop/browse/?appid=108600
  &searchtext=<query>
  &browsesort=textsearch        # or trend / toprated
  &section=readytouseitems
  &requiredtags[]=Build+42
  &p=<page>                     # 30 items/page
```

Helper:

```bash
S=.opencode/skills/pz-mod-search/scripts/pz-workshop-search.py
$S search sewing tailoring "sewing kit" --pages 5 --b42 --mp
$S search "car repair" mechanics --pages 3 --b42 --json > candidates.json
```

Notes:

- The page's "show incompatible items" checkbox is **not** a Build-42 filter —
  B41-only items still appear. Filter on the `Build 42` tag yourself.
- Use several narrow queries, not one broad one. A topic usually has 200+
  hits across synonyms (`tailoring`, `sewing`, `thread`, `needle`, `fabric`,
  `mending`; `mechanics`, `car repair`, `engine`, `salvage`, `parts`).
- Titles are noisy: "Learn More", duplicates, reuploads, translations. Dedupe
  on the item id, not the title.

## 2. Metadata (public Web API, no key)

```
POST https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/
     itemcount=N&publishedfileids[0]=<id>&publishedfileids[1]=<id>...
```

Batch 50, sleep ~0.3 s between calls. Fields that matter:

| Field | Use |
| --- | --- |
| `tags` | `Build 42`, `Multiplayer`, `Vehicles`, `Skills`, … |
| `subscriptions` | popularity smell test, not quality |
| `time_updated` | a mod untouched since early B42 is a risk |
| `description` | declared `Mod ID:`, requirements, conflicts (unreliable) |
| `creator` | find the author's other mods / a removed dependency |

```bash
$S details 3522680786 2757712197
```

## 3. Filter

1. **Require the `Build 42` tag.** The pack is B42 (42.20/42.21); B41-only mods
   are inert.
2. **Prefer the `Multiplayer` tag.** A server pack needs it.
3. **No MP tag ≠ broken, but verify.** Download and look at the Lua layout:
   - `media/lua/shared/` or `media/lua/server/` → server-side, usually fine.
   - items/recipes only (no Lua) → fine.
   - `media/lua/client/` only → UI; fine if it only renders, risky if it
     mutates state. Look for `sendClientCommand` + a matching `server/` handler
     (that is what makes `TailoringXP` MP-safe despite no tag).
4. **Reject SP-only outright** when the title says so (`[SP-Only]`,
   "Singleplayer only") or the author says MP is untested/WIP.
5. **Check `incompatible=` and the author's conflict notes** before adding a
   second mod in the same niche.

## 4. Verify (authoritative)

```bash
$S verify 3522680786 3816028300 --dir ~/pzws
```

`steamcmd` here is **bubblewrapped and cannot write under `/tmp`** (it fails
with `bwrap: Can't chdir to ...`). Use a directory under `$HOME`. The helper
sets `cwd=$HOME` too, for the same reason. Add `--login <name>` for
mature/gated items (`Access Denied` anonymously).

Then read every `mods/*/mod.info`:

| Key | Meaning |
| --- | --- |
| `id=` | **the string `Mods=` takes** (not the Workshop id, not the title) |
| `require=` | hard dependencies; comma-separated, often `\`-prefixed |
| `incompatible=` | do not enable together |
| `versionMin=` | minimum game build |
| `loadModAfter=` | explicit load-order hint |

Gotchas this catches:

- **`\` prefix**: `require=\TooltipLib,\errorMagnifier` means `TooltipLib` and
  `errorMagnifier`. Strip the `\`.
- **Multi-mod items**: `Craft Engine Parts` ships four mutually exclusive
  balance tiers (`CraftEngineParts`, `…Moderate`, `…Cheap`, `…Cheapest`);
  `Vehicle Repair Overhaul` hides its whole-vehicle salvage in a second mod;
  `Vanilla Vehicle Parts` ships one addon per vehicle pack; `GarageWorks`
  ships a safe-removal mod that declares `incompatible=GarageWorks`. Add only
  the mods you intend, never every folder.
- **Removed dependencies**: if `require=` names a mod that no longer exists,
  look for a blank **STUB** item carrying the same `Mod ID` (e.g.
  `Mod Update and Alert System [STUB]`, 3496670149, for
  `ChuckleberryFinnAlertSystem`). Without it the dependent mod may not load.
- **Description-only IDs are a hint.** `resolve`/`expand` prefill from
  `Mod ID:` in the description; that misses multi-mod items and hidden
  requires. `verify` wins.

## 5. Non-repetition

Before shortlisting, read the target pack and list what it already has:

```bash
grep -n 'id = ' modpacks/viewpoint.nix | head
nix eval --json .#modpacks.viewpoint.mods
```

Then:

- **Dedupe against the pack** by both Workshop id and Mod ID. A mod can arrive
  under a new Workshop id with the same Mod ID.
- **Group same-niche candidates and pick one.** Typical clusters:
  training automation, rip-all/batch, repair-count penalty, engine-repair
  formula, parts crafting, salvage, fluids, storage. Two mods in one cluster
  duplicate menus/recipes.
- **Check whether an installed mod already covers the feature** — e.g. `More
  Car Features` already adds tire/muffler repair and part smelting, which
  overlaps `Vehicle Repair Overhaul`; its sandbox toggles can turn those off.
- **Prefer the MP rewrite over the original** (`Better Auto Mechanics` replaces
  `Auto Mechanics`) and **remove the old entry** rather than keeping both.
- **One tier per item**: enable exactly one Craft Engine Parts difficulty.

## 6. Add to a pack

Edit `modpacks/<pack>.nix`:

```nix
workshopMods = [
  { id = "<digits>"; title = "<Workshop title>"; }
];
mods = [
  "<mod.info id= value>"   # NOT the Workshop id
];
```

- `WorkshopItems=` is semicolon-separated; `Mods=` is comma-separated. The
  module does the joining — you only edit the lists.
- **Order in `mods` is load order.** Dependencies first, `loadModAfter` hints
  honoured, and author instructions ("load last", "after vehicle mods") obeyed.
- Keep the two lists in sync and comment multi-mod items inline (`# one tier
  only`, `# STUB`, `# load last`).
- `failOnMissingMods` is on by default: a wrong Mod ID fails the boot rather
  than silently dropping the mod.

## 7. Validate

```bash
nix eval --json .#modpacks.viewpoint --apply 'p: {
  ws = builtins.length p.workshopMods;
  mods = builtins.length p.mods;
  uniqWs = builtins.length (builtins.attrNames (builtins.listToAttrs
    (map (m: { name = m.id; value = 1; }) p.workshopMods)));
  uniqMods = builtins.length (builtins.attrNames (builtins.listToAttrs
    (map (m: { name = m; value = 1; }) p.mods)));
}'
nix build --no-link .#checks.x86_64-linux.modpack-catalogue
nix build --no-link .#checks.x86_64-linux.module-eval
```

- Count with `nix eval`, **not** a regex over the `.nix` file: an entry with a
  trailing comment (`"ChuckleberryFinnAlertSystem" # STUB …`) is missed by a
  whole-line regex.
- `modpack-catalogue` is an **eval-time** check — it throws during evaluation
  and builds a trivial derivation. The same store path on two runs does not
  mean "unchanged"; success means the shape check passed.
- A pack-level boot test is still the only proof of load order; `dry-activate`
  and a scratch world are cheap.

## 8. Commit

One commit per topic, matching the repo style:

```
Add sewing/tailoring progression mods to viewpoint pack

<what and why; note the swap/removal; state MP verification; note
sub-mod choices and load order>
```

## Checklist

- [ ] Several narrow queries, ids deduped
- [ ] `Build 42` tag on every candidate; `Multiplayer` tag or verified
      structure
- [ ] SP-only / WIP / beta / untested-MP rejected
- [ ] `verify` run; every `mod.info` `id=` captured
- [ ] `require=` and `incompatible=` resolved (stub added if needed)
- [ ] multi-mod items split into only the intended mods
- [ ] compared against the pack (Workshop ids **and** Mod IDs)
- [ ] one mod per same-niche cluster; old overlapping mod removed
- [ ] `mods` order matches dependencies and author load-order notes
- [ ] `nix eval` counts + both checks pass
