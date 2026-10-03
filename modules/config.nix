# modules/config.nix
#
# Everything that is not a systemd unit: the service user and group, the
# data directory, evaluation-time assertions, and the reverse-proxy hook.
#
# Deliberately NOT here: any wiring into a specific reverse-proxy module.
# nixos-config has `my.services.proxy.upstreams`, but a standalone flake cannot
# depend on someone's private option namespace. Instead `webConsoleUpstreams`
# (bottom of this file) exposes plain data, and the consumer maps it into
# whatever it uses — see README 'Reverse proxy'.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge;

  cfg = config.services.project-zomboid-servers;
  pz = import ../lib { inherit lib; };

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg.servers;
  resolved = lib.mapAttrs (name: srv: pz.resolveServer cfg.modpacks name srv) enabledServers;

  # Every port an enabled server claims, tagged with the server that claims it.
  # PZ binds two UDP ports per instance; a silent clash produces two servers that
  # each bind half a socket and an error nobody can read, so it fails evaluation.
  claimedPorts = lib.concatMap (srv: [
    {
      port = srv.defaultPort;
      server = srv.serverName;
      what = "defaultPort";
    }
    {
      port = srv.udpPort;
      server = srv.serverName;
      what = "udpPort";
    }
  ]) (lib.attrValues resolved);

  portClashes =
    let
      byPort = lib.groupBy (c: toString c.port) claimedPorts;
      dupes = lib.filterAttrs (_: cs: lib.length cs > 1) byPort;
    in
    lib.mapAttrsToList (
      port: cs:
      "port ${port} is claimed by ${lib.concatMapStringsSep ", " (c: "${c.server} (${c.what})") cs}"
    ) dupes;

  # ── Web console upstreams ──────────────────────────────────────────────────
  # Plain data, no coupling to any particular reverse-proxy module. Consumers map
  # this into their own upstream option — see README 'Reverse proxy'.
  #
  # Ports are assigned in sorted server order so they stay stable as long as
  # servers are not renamed. This mirrors services.nix's `webPort`; if you change
  # one, change both.
  webServers = lib.filterAttrs (_: srv: cfg.web.enable && srv.webConsole) resolved;
  webPort =
    name:
    if resolved.${name}.port != null then
      resolved.${name}.port
    else
      cfg.web.portBase + (lib.length (builtins.filter (n: n < name) (builtins.attrNames webServers)));
in
{
  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          # Filled in by the flake's nixosModules wrapper; a bare import of the
          # module file (bypassing the wrapper) leaves it null.
          assertion = cfg.package != null;
          message = ''
            services.project-zomboid-servers.package is null.

            Import the module via the flake —
            `inputs.project-zomboid-servers.nixosModules.project-zomboid-servers` —
            so the launcher package can be supplied. Setting `package` yourself
            also works.
          '';
        }

        {
          assertion = portClashes == [ ];
          message = ''
            services.project-zomboid-servers: two enabled servers claim the same port.
            ${lib.concatStringsSep "\n" (map (c: "  - ${c}") portClashes)}

            Project Zomboid binds TWO UDP ports per instance (defaultPort and
            udpPort), and both must be free and unique across servers. Give each
            additional server its own pair.
          '';
        }

        {
          # Exactly one console backend. Two means two competing claims on the
          # same stdin; none means a server whose console cannot be reached or
          # stopped cleanly.
          assertion = lib.xor cfg.managementSystem.systemd-socket.enable cfg.managementSystem.tmux.enable;
          message = ''
            services.project-zomboid-servers: set exactly one of
            managementSystem.systemd-socket.enable or
            managementSystem.tmux.enable — got systemd-socket=${toString cfg.managementSystem.systemd-socket.enable},
            tmux=${toString cfg.managementSystem.tmux.enable}.
          '';
        }

        {
          # Same check per server, since servers may override the default.
          assertion = lib.all (
            srv:
            !srv.enable || lib.xor srv.managementSystem.systemd-socket.enable srv.managementSystem.tmux.enable
          ) (lib.attrValues cfg.servers);
          message = ''
            services.project-zomboid-servers: every enabled server must select
            exactly one console backend (systemd-socket or tmux). Both or
            neither leaves the console unreachable, or the server unstoppable.
          '';
        }

        {
          assertion = cfg.web.passwordFile == null || cfg.web.username != null;
          message = ''
            services.project-zomboid-servers: web.passwordFile is set but
            web.username is null, so the credential would be ":password".
            Set both, or neither.
          '';
        }
      ];

      # ── Service user / group ──────────────────────────────────────────────
      # Created conditionally on the name so `user`/`group` stay renameable.
      # Both halves are merged into one `users` attrset (and both `users.*`
      # sub-attrsets below are merged into it) so nothing is silently dropped.
      users =
        lib.optionalAttrs (cfg.user == "project-zomboid") {
          users.project-zomboid = {
            isSystemUser = true;
            group = cfg.group;
            home = cfg.dataDir;
            createHome = true;
            homeMode = "0770";
            description = "Project Zomboid dedicated server";
          };
          groups.project-zomboid = { };
        }
        // lib.optionalAttrs cfg.web.enable {
          users.${cfg.web.user} = {
            isSystemUser = true;
            group = cfg.group;
            shell = pkgs.bashInteractive;
          };
        };

      # The data dir must exist before any unit writes into it. tmpfiles rather
      # than createHome alone, because a server's Zomboid home is created
      # per-server by ExecStartPre and the top-level dir must be writable.
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
        "d '${cfg.serverDir}' 0755 ${cfg.user} ${cfg.group} - -"
      ];

      # ── Console user, scoped sudo, proxy upstreams ─────────────────────────
      security.sudo.extraRules = lib.optionalAttrs cfg.web.enable [
        {
          users = [ cfg.web.user ];
          # Exactly the verbs the web shim exposes, and only these units.
          commands =
            map
              (verb: {
                command = "${pkgs.systemd}/bin/systemctl ${verb} project-zomboid-*";
                options = [ "NOPASSWD" ];
              })
              [
                "start"
                "stop"
                "restart"
                "status"
              ];
        }
      ];

      services.project-zomboid-servers.webConsoleUpstreams = pz.mkProxyUpstreams {
        inherit webServers webPort;
      };
    })
  ];
}
