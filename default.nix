# default.nix
#
# flake-compat shim, so this flake can be consumed without flakes:
#
#   nix-build -E '(import (fetchTarball "https://github.com/you/nixos-projectzomboid-servers")).nixosModules.default'
#
# Only the module is bridged, because that is all a non-flake NixOS consumer can
# actually use: the catalogue and the checks are flake outputs, and a non-flake
# consumer reads the catalogue straight off the filesystem instead.
#
# Explicitly unsupported here: `nixos-rebuild` without flakes needs a
# `configuration.nix`, which is the consumer's business, not this project's.
{ flake }:
let
  inherit (flake.inputs) nixpkgs;

  overlay = import ./overlay.nix;
in
{
  # `<nixpkgs-overlays>` style consumers add this to their package set.
  inherit overlay;

  # NixOS consumers import this from their module list.
  nixosModules = {
    default = flake.nixosModules.default;
    project-zomboid-servers = flake.nixosModules.project-zomboid-servers;
  };

  # The catalogue, for a consumer that wants it as an attrset.
  modpacks = import ./modpacks { lib = nixpkgs.lib; };
}
