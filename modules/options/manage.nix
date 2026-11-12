# modules/options/manage.nix
#
# The pz-manage dashboard and its JSON API.
{ lib, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.services.project-zomboid-servers = {
    # ── Management dashboard ─────────────────────────────────────────────────

    manage = {
      enable = mkEnableOption "the pz-manage dashboard and JSON API";

      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Interface to bind. Defaults to loopback: the dashboard is meant to be
          exposed through the host's reverse proxy (with its authentication),
          a tailnet, or a ZeroTier network — never the public internet. RCON is
          plaintext and the service has no user database of its own.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 27080;
        description = "Loopback TCP port for the dashboard and its API.";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          User the dashboard runs as. <literal>null</literal> uses
          <option>web.user</option>, which is already granted a scoped polkit
          rule for <literal>manage-units</literal> on the
          <literal>project-zomboid-*</literal> units. It must be in
          <option>group</option> to read the data directory and any
          <option>secretFiles</option> the host marks group-readable.
        '';
      };

      title = mkOption {
        type = types.str;
        default = "Project Zomboid";
        description = "Heading shown by the dashboard.";
      };

      consoleBase = mkOption {
        type = types.str;
        default = "/pz";
        description = ''
          URL prefix the host's reverse proxy uses for the ttyd consoles. Only
          used to render the console link; the dashboard does not proxy it.
        '';
      };

      refreshSeconds = mkOption {
        type = types.int;
        default = 5;
        description = "How often the dashboard refreshes status, players and the log tail.";
      };

      allowActions = mkOption {
        type = types.listOf (
          types.enum [
            "save"
            "broadcast"
            "kick"
            "ban"
            "unban"
            "whitelist-add"
            "whitelist-remove"
            "reload-options"
            "start"
            "stop"
            "restart"
          ]
        );
        default = [
          "save"
          "broadcast"
          "kick"
          "ban"
          "unban"
          "whitelist-add"
          "whitelist-remove"
          "reload-options"
          "start"
          "stop"
          "restart"
        ];
        description = ''
          Actions the API will perform. Each maps to one fixed RCON command or
          one <command>systemctl</command> verb — there is no raw RCON terminal
          and no arbitrary command execution. Remove an entry to disable that
          action without changing the dashboard.

          <option>start</option>, <option>stop</option> and
          <option>restart</option> go through the polkit rule the module
          installs for <option>web.user</option>; they never spawn the game
          process directly.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open <option>port</option>.

          Off by default. The dashboard has no user database of its own: it
          trusts the reverse proxy or private network in front of it, so opening
          this port directly exposes an unauthenticated control API. Use a proxy,
          a tailnet, or an ACL instead.
        '';
      };
    };
  };
}
