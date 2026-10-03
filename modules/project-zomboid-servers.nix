# modules/project-zomboid-servers.nix
#
# The NixOS module. Consumers get it as
# `inputs.project-zomboid-servers.nixosModules.project-zomboid-servers`.
#
# Split across three files by concern:
#   options.nix   every option, and nothing else
#   config.nix    user/group, tmpfiles, assertions, the proxy hook
#   services.nix  the systemd units
#
# Note there is no `package` wiring here: the flake cannot hand its own package
# to a module through this file, because a flake input's module scope has no
# reference back to `self`. The flake's `nixosModules` wrapper does that with
# `mkDefault` instead — see flake.nix. That is why `package` defaults to null
# here rather than to `pkgs.project-zomboid-server`, which would require the
# consumer to also add this flake's overlay.
{ ... }:

{
  imports = [
    ./options.nix
    ./config.nix
    ./services.nix
  ];
}
