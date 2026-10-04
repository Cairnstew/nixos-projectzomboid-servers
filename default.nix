# default.nix — the non-flake entry point.
#
# The top level is a plain ATTRSET, deliberately, because that is what makes the
# obvious non-flake incantation work:
#
#   # in a non-flake configuration.nix
#   imports = [
#     (import (builtins.fetchTarball {
#       url = "https://github.com/you/repo/archive/main.tar.gz";
#     })).nixosModules.default
#   ];
#
# Selecting `.nixosModules` straight off an `import` requires the imported file
# to evaluate to an attrset. The first version of this file was a function of
# `{ flake }`, so that expression failed with
#
#   error: expected a set but found a function
#
# …while the file's own comment advertised it. A function top level is only
# reachable as `(import path) { … }`, which is the flake-compat calling
# convention; flake-compat is not how anyone should consume this, because its job
# is to let a NON-flake consumer read a consumer's flake outputs, and here the
# consumer is importing us directly. `builtins.fetchTarball` is both simpler and
# the shape that works.
#
# What a non-flake consumer gets, and nothing more:
#
#   nixosModules.default                 the module, with `package` supplied
#   nixosModules.project-zomboid-servers the same module under a stable name
#   modpacks                             the catalogue, as a plain attrset
#   lib                                  resolveServer / renderIniLines / …
#   overlay                              adds pkgs.project-zomboid-server
#
# Not bridged: `apps`, `checks`, `devShells`, `packages`, `formatter`, `lib.tests`.
# Those are per-system flake outputs, or need nixpkgs' full `lib` — see the note
# on `lib` below.
let
  # nixpkgs' `lib`, used ONLY for the catalogue and the shared helper library —
  # both of which need nothing beyond string/list/attrset functions.
  #
  # Deliberately NOT an instantiated package set. Building one here would mean
  # choosing a channel behind the consumer's back and then handing the module a
  # `pkgs` that is not theirs; see `pzModule` below. This is also why unfree is
  # not enabled anywhere in this file: the consumer's own `nixpkgs` decides that,
  # and they have to allow it regardless, because the module's own `steamcmd` and
  # `steamRun` options default to unfree Steamworks packages.
  lib = (import <nixpkgs> { }).lib;

  # The module.
  #
  # `modules/project-zomboid-servers.nix` cannot reference `self`, because a
  # flake input's module scope has no path back to its own flake. So `package`
  # defaults to null over there (see modules/options.nix, and the assertion in
  # modules/config.nix that explains it), and something has to fill it in.
  #
  # It is built with `pkgs.callPackage` on the CONSUMER'S package set — the same
  # trick flake.nix's `lib/tests.nix` already uses. That matters: an earlier
  # version of this file imported `<nixpkgs>` here and handed the module its own
  # `pkgs.project-zomboid-server`, which broke the moment the consumer passed
  # their own `nixpkgs.pkgs` (or used a different channel), with
  # "attribute 'project-zomboid-server' missing". Deriving it from the module's
  # own `pkgs` argument cannot go stale that way.
  #
  # `mkDefault`, so an explicit `package` set by the consumer still wins.
  pzModule =
    { pkgs, lib, ... }:
    {
      imports = [ ./modules/project-zomboid-servers.nix ];

      config.services.project-zomboid-servers = {
        package = lib.mkDefault (pkgs.callPackage ./pkgs/project-zomboid-server { });
      };
    };
in
{
  # For `<nixpkgs-overlays>` consumers who want to reach the launcher from their
  # own package set. nixpkgs calls this with BOTH `final` and `prev`, which is
  # why an overlay is written `final: _prev: { … }`.
  overlay = import ./overlay.nix;

  nixosModules = {
    default = pzModule;
    project-zomboid-servers = pzModule;
  };

  # The catalogue, as plain data — no module, no `pkgs`.
  modpacks = import ./modpacks { inherit lib; };

  # The shared library the flake exports as `self.lib`: `resolveServer`,
  # `renderIniLines`, `renderSandbox`, `mkProxyUpstreams`. A consumer writing
  # their own modpack, or merging rendered config into something else, wants
  # these; they only use helpers present in the reduced `lib` above.
  #
  # `tests.eval` is deliberately absent. It calls `lib.nixosSystem`, which lives
  # in nixpkgs' *own* `lib` output and not in the instantiated package set's:
  # `(import <nixpkgs> {}).lib ? nixosSystem` is `false`. Reaching the full `lib`
  # without flakes means reaching into `<nixpkgs>`'s internals, so `tests` stays a
  # flake-only output. Call `nixpkgs.lib.nixosSystem` directly instead, which is
  # what any real non-flake configuration does anyway.
  lib = import ./lib { inherit lib; };
}