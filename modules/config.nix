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

  # TCP services this host exposes: RCON, the dashboard and the ttyd consoles.
  # Kept separate from `claimedPorts` because a UDP and a TCP service may share a
  # number without a clash — but two TCP listeners may not.
  #
  # `webServers`/`webPort` are defined below; `let` bindings are recursive, so
  # this deliberately reaches forward rather than duplicating the assignment.
  tcpClaims =
    lib.concatMap (
      srv:
      lib.optional (srv.rconPort != 0) {
        port = srv.rconPort;
        server = srv.serverName;
        what = "rconPort";
      }
    ) (lib.attrValues resolved)
    ++ lib.optional cfg.manage.enable {
      port = cfg.manage.port;
      server = "(dashboard)";
      what = "manage.port";
    }
    ++ lib.concatMap (
      name:
      lib.optional (webServers ? ${name}) {
        port = webPort name;
        server = name;
        what = "web console";
      }
    ) (builtins.attrNames webServers);

  tcpPortClashes =
    let
      byPort = lib.groupBy (c: toString c.port) tcpClaims;
      dupes = lib.filterAttrs (_: cs: lib.length cs > 1) byPort;
    in
    lib.mapAttrsToList (
      port: cs:
      "TCP port ${port} is claimed by ${lib.concatMapStringsSep ", " (c: "${c.server} (${c.what})") cs}"
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

  # `idleStop` decides "empty" by asking RCON for the player list. Without RCON
  # there is no honest way to tell an empty server from one still loading, and
  # guessing would stop a server that is merely slow to boot. Fail at
  # evaluation rather than ship a timer that silently does nothing.
  badIdleStops = lib.concatMap (
    srv:
    lib.optional (srv.idleStop.enable && (srv.rconPort == 0 || !(srv.secretFiles ? RCONPassword)))
      "${srv.name}: idleStop.enable needs rconPort and secretFiles.RCONPassword (got rconPort=${toString srv.rconPort}, RCONPassword=${
        if srv.secretFiles ? RCONPassword then "set" else "missing"
      })"
  ) (lib.attrValues resolved);

  # ── Dedicated Workshop directory ───────────────────────────────────────────
  # The install script derives the steamcmd library root by stripping this
  # suffix, so a path that does not have it would either download elsewhere or
  # refuse at run time. Catching it at evaluation is the difference between a
  # readable error and a failed oneshot unit.
  workshopSuffix = "/steamapps/workshop/content/${
    if cfg.package == null then "108600" else cfg.package.steamAppId
  }";
  badWorkshopDirs =
    let
      dir = toString cfg.workshopDir;
    in
    lib.optional (!(lib.hasPrefix "/" dir)) "workshopDir is not absolute: ${dir}"
    ++ lib.optional (
      !(lib.hasSuffix workshopSuffix dir)
    ) "workshopDir must end with ${workshopSuffix}: ${dir}";

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
  # The port assignment itself lives in `lib` so this file and services.nix use
  # exactly the same function; see `pz.mkWebPort`.
  webServers = lib.filterAttrs (_: srv: cfg.web.enable && srv.webConsole) resolved;
  webPort = pz.mkWebPort {
    inherit (cfg.web) portBase;
    inherit resolved webServers;
  };

  # The dashboard runs as the web-console user by default, because that user is
  # already the one granted the scoped polkit rule below. A host may point it
  # at another existing user; this module does not create that user.
  manageUser = if cfg.manage.user != null then cfg.manage.user else cfg.web.user;
  unitManagers = lib.unique ([ cfg.web.user ] ++ lib.optional cfg.manage.enable manageUser);
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
          assertion = tcpPortClashes == [ ];
          message = ''
            services.project-zomboid-servers: two TCP services claim the same port.
            ${lib.concatStringsSep "\n" (map (c: "  - ${c}") tcpPortClashes)}

            RCON, the pz-manage dashboard and every ttyd console are TCP
            listeners on this host. Keep `rconPort`, `manage.port` and each
            server's web-console `port` distinct, including the ports assigned
            automatically from `web.portBase`.
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
          assertion = badIdleStops == [ ];
          message = ''
            services.project-zomboid-servers: idleStop needs RCON.
            ${lib.concatStringsSep "\n" (map (b: "  - ${b}") badIdleStops)}

            The idle check reads the player list over RCON. Set a non-zero
            `rconPort` and `secretFiles.RCONPassword = /run/agenix/...` on the
            server, or disable `idleStop`. Without RCON the module cannot tell an
            empty server from one that is still booting, so it refuses to guess.
          '';
        }

        {
          assertion = badWorkshopDirs == [ ];
          message = ''
            services.project-zomboid-servers: invalid workshopDir.
            ${lib.concatStringsSep "\n" (map (b: "  - ${b}") badWorkshopDirs)}

            SteamCMD installs Workshop content under a Steam library root, at
            `<library>/steamapps/workshop/content/<appid>`. Point workshopDir at
            that final directory (it must be absolute), and the module derives
            the library root to pass to steamcmd.
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

        {
          # The reverse direction of the check above. `needsAuth` in
          # services.nix requires BOTH options, so a username without a password
          # silently starts an unauthenticated ttyd rather than failing.
          assertion = cfg.web.username == null || cfg.web.passwordFile != null;
          message = ''
            services.project-zomboid-servers: web.username is set but
            web.passwordFile is null, so the ttyd consoles would start WITHOUT
            authentication. Set both, or neither.
          '';
        }
      ];

      # Unauthenticated control planes are a local-privilege issue, not only a
      # network one: loopback is reachable by every local user, and the ttyd
      # shim's .start/.stop/.restart go through the module's polkit rule.
      warnings =
        lib.optional (cfg.web.enable && cfg.web.username == null) ''
          services.project-zomboid-servers.web.enable is on but web.username /
          web.passwordFile are unset: the ttyd consoles are unauthenticated.
          Any local user who can reach ${cfg.web.bind} can send console commands,
          including .start/.stop/.restart through the polkit rule. Set both
          options, or expose the consoles only through an authenticating proxy
          or a tailnet.
        ''
        ++ lib.optional (cfg.web.enable && cfg.web.username != null) ''
          services.project-zomboid-servers: the ttyd basic-auth password is passed
          to ttyd with --credential, so it is visible in the process list
          (`ps`, /proc/<pid>/cmdline). Prefer proxy authentication and leave
          web.username/web.passwordFile unset, or accept that local disclosure.
        ''
        ++ lib.optional (cfg.manage.enable && cfg.manage.openFirewall) ''
          services.project-zomboid-servers.manage.openFirewall is on, but the
          dashboard has no user database of its own: it trusts the reverse proxy
          or private network in front of it. Do not open manage.port directly
          without an authenticating proxy or a network ACL.
        '';

      # ── Service user / group ──────────────────────────────────────────────
      # Created conditionally on the name so `user`/`group` stay renameable.
      # Both halves MUST be deep-merged: `//` is shallow, and both halves carry a
      # `users` key, so `a // b` would let the web-console half's `users` REPLACE
      # the server half's — silently deleting the `project-zomboid` user (while
      # keeping its group, which only the left half defines) the moment
      # `web.enable` is turned on. The running server then dies on its next stop
      # or start with `Failed to determine credentials for user
      # 'project-zomboid': Unknown user` (status=217/USER). Caught on the first
      # host to enable the console after servers were already running.
      users =
        lib.recursiveUpdate
          (lib.optionalAttrs (cfg.user == "project-zomboid") {
            users.project-zomboid = {
              isSystemUser = true;
              group = cfg.group;
              home = cfg.dataDir;
              createHome = true;
              homeMode = "0770";
              description = "Project Zomboid dedicated server";
            };
            groups.project-zomboid = { };
          })
          (
            lib.optionalAttrs (cfg.web.enable || cfg.manage.enable) {
              users.${cfg.web.user} = {
                isSystemUser = true;
                group = cfg.group;
                shell = pkgs.bashInteractive;
              };
            }
          );

      # The data dir must exist before any unit writes into it. tmpfiles rather
      # than createHome alone, because a server's Zomboid home is created
      # per-server by ExecStartPre and the top-level dir must be writable.
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
        "d '${cfg.serverDir}' 0755 ${cfg.user} ${cfg.group} - -"
      ];

      # ── Console user, scoped unit control, proxy upstreams ─────────────────
      # polkit, NOT sudoers. A scoped `security.sudo.extraRules` entry looks
      # right but is unreachable on any host that sets
      # `security.sudo.execWheelOnly = true` (a common hardening): that option
      # makes the sudo wrapper itself executable by the `wheel` group only, so a
      # service user like `project-zomboid-web` gets
      # "sudo: unable to execute /run/wrappers/bin/sudo: Permission denied"
      # before the rule is ever consulted. Putting the user in `wheel` instead is
      # not an option — with `wheelNeedsPassword = false` that grants full
      # passwordless root. polkit grants exactly the one action on exactly these
      # units, and `systemctl` consults it automatically.
      security.polkit.extraConfig = lib.optionalString (cfg.web.enable || cfg.manage.enable) ''
        // Project Zomboid web console and dashboard: let the console/dashboard
        // user manage its own units and nothing else. Matches the
        // `project-zomboid-` unit prefix, mirroring what a scoped sudoers rule
        // would have allowed.
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              (${lib.concatMapStringsSep " || " (user: "subject.user == \"${user}\"") unitManagers})) {
            var unit = action.lookup("unit");
            if (unit && unit.indexOf("project-zomboid-") === 0) {
              return polkit.Result.YES;
            }
          }
        });
      '';

      services.project-zomboid-servers.webConsoleUpstreams = pz.mkProxyUpstreams {
        inherit webServers webPort;
      };
    })
  ];
}
