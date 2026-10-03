# overlay.nix
#
# Exposes the launcher wrapper as `pkgs.project-zomboid-server`.
#
# Consumers do not need this: the flake's `nixosModules` wrapper already supplies
# the package to the module with `mkDefault`. It exists for the two cases that
# cannot get there — a non-flake consumer, or someone who wants to reach the
# wrapper from their own package set.
final: _prev: {
  project-zomboid-server = final.callPackage ./pkgs/project-zomboid-server { };
}
