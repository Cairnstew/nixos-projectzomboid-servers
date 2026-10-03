# modpacks/default.nix
#
# The modpack catalogue. This is DATA, not a NixOS module: it is exported as
# `self.modpacks` and contains no `config`, no option paths and no `pkgs`, so a
# consumer can read it, extend it or ignore it without importing a module.
#
# A consumer wires the whole catalogue in with:
#
#   services.project-zomboid-servers.modpacks = inputs.project-zomboid-servers.modpacks;
#
# …or cherry-picks:
#
#   services.project-zomboid-servers.modpacks = {
#     vanilla-plus = inputs.project-zomboid-servers.modpacks.vanilla-plus;
#   };
#
# Each `<name>.nix` in this directory (except this aggregator) defines exactly
# one pack, returning an attrset with the keys:
#
#   description     str            human-readable summary
#   workshopMods    [ { id, title } ]   Steam Workshop items, order preserved
#   mods            [ str ]        local mod folder names (mod.info `id=` values)
#   defaultSettings attrset        .ini keys servers inherit
#   defaultSandbox  attrset        SandboxVars servers inherit
#
# Adding a pack means dropping in a file — no registration step.
{ lib }:

let
  dir = ./.;

  # `builtins.readDir` returns names WITH the extension, so filter on `.nix` and
  # then strip it — otherwise the catalogue keys are "vanilla-plus.nix" and a
  # server's `modpack = "vanilla-plus"` fails to resolve.
  packFiles = map (lib.removeSuffix ".nix") (
    lib.filter (name: lib.hasSuffix ".nix" name && name != "default.nix") (
      lib.attrNames (builtins.readDir dir)
    )
  );
in
lib.genAttrs packFiles (name: import "${dir}/${name}.nix")
