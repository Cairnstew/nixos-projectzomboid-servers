# modules/options.nix
#
# Options for `services.project-zomboid-servers`.
#
# Namespace mirrors nix-minecraft's `services.minecraft-servers` (plural,
# because it manages a *set* of servers), since this project is the PZ
# equivalent of that module.
#
# The declarations live in `options/` by concern; the shared submodule types
# are in `options/types.nix`. This file is the single import point.
{ ... }:

{
  imports = [
    ./options/core.nix
    ./options/servers.nix
    ./options/client-hosts.nix
    ./options/web.nix
    ./options/manage.nix
    ./options/backup.nix
  ];
}
