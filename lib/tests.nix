# lib/tests.nix
#
# An evaluation helper, exported as `self.lib.tests.eval`.
#
# This exists so the flake's checks (and anyone testing a change to this module)
# can evaluate a NixOS configuration WITHOUT booting a VM. It runs
# `lib.nixosSystem`, so it exercises real module wiring, merging, `assertions`
# and `systemd.services` generation — everything except the parts that need a
# running system.
#
# Note it must be `nixosSystem`, not plain `lib.evalModules`: `assertions` and
# the rest of the NixOS option surface are defined by NixOS's own module list,
# which `evalModules` does not pull in. A module that sets `assertions` fails
# under bare `evalModules` with "The option `assertions' does not exist".
#
# `pkgs` is a per-call argument rather than bound here, because binding it would
# mean calling `builtins.currentSystem` — an impure builtin that is unavailable
# inside a pure flake evaluation, so a consumer's flake would fail to evaluate
# this output at all.
#
# Usage:
#
#   let
#     evaluated = inputs.project-zomboid-servers.lib.tests.eval {
#       inherit pkgs;
#       config.services.project-zomboid-servers = { enable = true; };
#     };
#   in evaluated.config.systemd.services
#
# You do not normally import this: `nix flake check` already runs the
# `module-eval` check that uses it.
{ lib }:

let
  # The bare minimum a NixOS evaluation needs to get far enough to have
  # systemd.services: a root filesystem and a state version. No bootloader, so
  # nothing needs building in order to evaluate.
  baseConfig = {
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    # Deliberately NOT `nixpkgs.config.allowUnfree`: `eval` supplies an
    # externally-created `pkgs`, and NixOS asserts that `nixpkgs.config` is unset
    # in that case ("Your system configures nixpkgs with an externally created
    # instance"). Unfree is enabled on the package set below instead.
    system.stateVersion = "25.05";
  };
in
{
  # Evaluate `config` on top of the module.
  #
  #   pkgs          required — the package set to evaluate against
  #   system        defaults to `pkgs`' own system
  #   config        option values to set
  #   extraImports  your own modules (a good way to assert on a consumer's wiring)
  #                 NOTE: if those modules import
  #                 `inputs.project-zomboid-servers.nixosModules.…`, they will
  #                 collide with this helper's own `package` injection — two
  #                 `mkDefault`s at the same priority conflict. In that case call
  #                 `nixpkgs.lib.nixosSystem` directly instead, which is what a real
  #                 consumer does anyway and what examples/single-server does.
  #   extraArgs     exposed to those modules via `_module.args`, so a config file
  #                 that takes the flake as an argument can be imported unchanged
  #   base          extends the minimal base configuration
  eval =
    {
      pkgs,
      system ? pkgs.stdenv.hostPlatform.system,
      config ? { },
      extraImports ? [ ],
      extraArgs ? { },
      base ? { },
    }:
    let
      # Two adjustments to the incoming package set, both as plain attrset
      # overrides rather than `pkgs.extend` (which this Nix evaluates as a call
      # on a set):
      #
      #   * the launcher is not in nixpkgs, so add it rather than requiring the
      #     consumer to have applied this flake's overlay;
      #   * allow unfree, since the launcher and steam-run are Steamworks
      #     packages.
      pkgs' = pkgs // {
        config = pkgs.config // {
          allowUnfree = true;
        };
        project-zomboid-server = pkgs.callPackage ../pkgs/project-zomboid-server { };
      };
    in
    lib.nixosSystem {
      inherit system;
      # `pkgs'` so a module under test that takes `pkgs` also sees the launcher.
      pkgs = pkgs';
      specialArgs = extraArgs;
      modules = [
        (import ../modules/project-zomboid-servers.nix)
        (baseConfig // base)
        { inherit config; }
        # The module file cannot reach the flake's package, so supply it the
        # same way the flake's nixosModules wrapper does.
        {
          _file = "project-zomboid-servers/tests/package.nix";
          config.services.project-zomboid-servers = {
            package = lib.mkDefault pkgs'.project-zomboid-server;
          };
        }
      ]
      ++ extraImports;
    };
}
