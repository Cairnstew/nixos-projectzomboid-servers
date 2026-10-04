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

  # ── Secret leakage ─────────────────────────────────────────────────────────
  # The Nix-rendered base `.ini` and SandboxVars are `pkgs.writeText` store
  # paths: mode 444, world-readable, greppable by any local user. So a secret
  # placed in `settings` or `sandbox` is a plaintext file in /nix/store, not a
  # secret.
  #
  # Checked against the RESOLVED settings (modpack defaults included), because a
  # secret can arrive either way, and against `sandbox` for the same reason.
  #
  # This is the user-facing control; `pz.renderIniLines` independently filters the
  # same keys, so a bare module import that skipped this assertion still cannot
  # write one.
  secretLeaks = lib.concatMap (
    srv:
    let
      inIni = lib.filter (k: builtins.elem k pz.secretIniKeys) (builtins.attrNames srv.settings);
      inSandbox = lib.filter (k: builtins.elem k pz.secretIniKeys) (builtins.attrNames srv.sandbox);
    in
    map (k: "${srv.name}: ${k} is set in settings") inIni
    ++ map (k: "${srv.name}: ${k} is set in sandbox") inSandbox
  ) (lib.attrValues resolved);

  # ── Map resolution ─────────────────────────────────────────────────────────
  # `map = null` means "derive Map= from the installed mods", which needs a base
  # map to anchor the list — and needs detection actually enabled, or the value
  # would silently never be computed.
  badMapConfigs = lib.concatMap (
    srv:
    lib.optional (srv.autoMaps && (!srv.mapOrder.enable || srv.baseMap == ""))
      "${srv.name}: map is null (auto-detect) but mapOrder.enable is false and baseMap is empty, so Map= would never be set"
  ) (lib.attrValues resolved);

  # ── Beta branch coherence ──────────────────────────────────────────────────
  # The shared install unit applies ONE branch, so servers on the same install
  # disagreeing about it means one of them silently gets the wrong build.
  betaBranches = lib.unique (map (srv: srv.betaBranch) (lib.attrValues resolved));
  # null rather than [] when the branches agree: `lib.optional` yields an empty
  # LIST, and interpolating that into a message is a type error.
  betaMismatch =
    if builtins.length betaBranches > 1 then
      lib.concatStringsSep ", " (map (b: if b == null then "(stable)" else b) betaBranches)
    else
      null;

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
            services.project-zomboid-servers.package is null, so no launcher
            package is available and no server units were defined.

            The module file cannot name its own package, because a flake input's
            module scope has no path back to its flake. Import it through one of
            the entry points that fills `package` in for you:

              flake       inputs.project-zomboid-servers.nixosModules.project-zomboid-servers
              non-flake   (import (builtins.fetchTarball "…")).nixosModules.default

            Or set it yourself:

              package = pkgs.project-zomboid-server;   # needs this flake's overlay

            Also note that Project Zomboid is unfree, so `allowUnfree` must be
            true in your nixpkgs config.
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
          assertion = secretLeaks == [ ];
          message = ''
            services.project-zomboid-servers: a secret is set in `settings` or
            `sandbox`, which would publish it.
            ${lib.concatStringsSep "\n" (map (leak: "  - ${leak}") secretLeaks)}

            The rendered `.ini` and SandboxVars are Nix store paths: mode 444 and
            readable by every local user, so anything in them is not a secret.
            Route each of these through a file instead —
            `secretFiles.<Key> = /run/secrets/...` (or `passwordFile` for the
            join password). `passwordFile`, `adminAccount.passwordFile` and
            `web.passwordFile` all take the same shape.
          '';
        }

        {
          assertion = badMapConfigs == [ ];
          message = ''
            services.project-zomboid-servers: inconsistent map configuration.
            ${lib.concatStringsSep "\n" (map (b: "  - ${b}") badMapConfigs)}

            Either give the server an explicit `map`, or leave `map` null and keep
            `mapOrder.enable = true` with a non-empty `baseMap` so `Map=` can be
            derived from the installed mods.
          '';
        }

        {
          assertion = betaMismatch == null;
          message = ''
            services.project-zomboid-servers: servers disagree on `betaBranch`.
              found: ${lib.optionalString (betaMismatch != null) betaMismatch}

            The dedicated server is installed ONCE per `serverDir`, so a single
            branch applies to every server on it. Set `betaBranch` on all of them,
            or on none.
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
