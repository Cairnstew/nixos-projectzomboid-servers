# modules/manage.nix
#
# The pz-manage dashboard, its JSON API, and scheduled backups.
#
# This is the half of a control panel that a declarative module can own
# honestly. It reads systemd and RCON, performs transient actions through
# fixed verbs, and never writes a file the Nix render owns: `viewpoint.ini`,
# `_SandboxVars.lua`, `Mods=` and `WorkshopItems=` are re-applied on every
# start, so a web editor for them would be a lie. See
# docs/plans/control-panel-parity.md for the feature-by-feature decision.
#
# The Python sources live in modules/manage/. They are stdlib-only, so the
# service needs no virtualenv, no npm build and no network at runtime.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.project-zomboid-servers;
  pz = import ../lib { inherit lib; };

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg.servers;
  resolved = lib.mapAttrs (name: srv: pz.resolveServer cfg.modpacks name srv) enabledServers;
  serverNames = builtins.attrNames resolved;

  manageEnabled = cfg.manage.enable;
  backupEnabled = cfg.backup.enable;
  # Both features read the same rendered description of the servers, so it is
  # produced whenever either is on.
  anyEnabled = manageEnabled || backupEnabled;

  manageUser = if cfg.manage.user != null then cfg.manage.user else cfg.web.user;

  backupRoot =
    if cfg.backup.directory != null then cfg.backup.directory else "${cfg.dataDir}/backups";

  # One JSON document, rendered by Nix, read by both Python entry points.
  #
  # It deliberately contains no secret VALUES: the RCON password is a path to a
  # file the service user can read, and the `.ini`/sandbox maps have the
  # module's secret keys stripped again here (the assertion in config.nix is
  # the first line of defence; this is the second).
  manageConfig = {
    title = cfg.manage.title;
    bind = cfg.manage.bind;
    port = cfg.manage.port;
    refreshSeconds = cfg.manage.refreshSeconds;
    allowActions = cfg.manage.allowActions;
    servers = map (
      name:
      let
        srv = resolved.${name};
      in
      {
        name = name;
        serverName = srv.serverName;
        description = srv.description;
        unit = "project-zomboid-${name}";
        home = "${cfg.dataDir}/${name}";
        zomboidDir = "${cfg.dataDir}/${name}/Zomboid";
        logsDir = "${cfg.dataDir}/${name}/Zomboid/Logs";
        defaultPort = srv.defaultPort;
        udpPort = srv.udpPort;
        rconPort = srv.rconPort;
        # The dashboard and the server share a host, so RCON never leaves the
        # loopback interface. A remote deployment can override this in the
        # rendered JSON, but the default is the safe one.
        rconHost = "127.0.0.1";
        rconPasswordFile = srv.secretFiles.RCONPassword or null;
        consolePath = if cfg.web.enable && srv.webConsole then "${cfg.manage.consoleBase}/${name}/" else "";
        modpack = srv.modpack;
        maxPlayers = srv.settings.maxPlayers;
        public = srv.settings.public or null;
        map = srv.pinnedMap;
        settings = removeAttrs srv.settings pz.secretIniKeys;
        sandbox = removeAttrs srv.sandbox pz.secretIniKeys;
        mods = srv.mods;
        workshopItems = srv.workshopItems;
        backupDirectory = "${backupRoot}/${name}";
        backupKeep = cfg.backup.keep;
      }
    ) serverNames;
  };

  manageConfigFile = pkgs.writeText "project-zomboid-manage.json" (builtins.toJSON manageConfig);

  # Shared by both units: tar and zstd are invoked by backups.py, systemctl by
  # both, and the Python entry point is absolute anyway.
  runtimePath = [
    pkgs.systemd
    pkgs.coreutils
    pkgs.gnutar
    pkgs.zstd
  ];

  restoreCommand = pkgs.writeShellApplication {
    name = "project-zomboid-restore";
    runtimeInputs = [
      pkgs.systemd
      pkgs.gnutar
      pkgs.zstd
      pkgs.coreutils
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./manage}/backups.py \
        --config ${manageConfigFile} restore "$@"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # The backup tree may live on another disk; create it with the right owner
    # before either unit writes into it. Group-writable because the dashboard
    # runs as the web user and the timer as the server user, and both create
    # archives.
    systemd.tmpfiles.rules = lib.mkIf anyEnabled [
      "d '${backupRoot}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.project-zomboid-manage = lib.mkIf manageEnabled {
      description = "Project Zomboid management dashboard";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = runtimePath;

      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./manage}/server.py";
        User = manageUser;
        Group = cfg.group;

        Environment = [
          "PZ_MANAGE_CONFIG=${manageConfigFile}"
          "PZ_MANAGE_STATIC=${./manage}/static"
          "PYTHONDONTWRITEBYTECODE=1"
        ];

        Restart = "on-failure";
        RestartSec = "2s";

        # The service only needs to read the world and write the backup tree.
        # It talks to systemd over the system bus (AF_UNIX), to RCON over
        # loopback (AF_INET), and to browsers through the proxy.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        # The `-` prefix makes a missing path non-fatal: the backup tree is
        # created by the tmpfiles rule above, and on a first switch this unit
        # can start before that rule has run.
        ReadOnlyPaths = [ "-${cfg.dataDir}" ];
        ReadWritePaths = [ "-${backupRoot}" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    # ── Scheduled backups ───────────────────────────────────────────────────
    systemd.services.project-zomboid-backup = lib.mkIf backupEnabled {
      description = "Back up Project Zomboid worlds";
      after = [ "network.target" ];

      path = runtimePath ++ [ pkgs.python3 ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${pkgs.python3}/bin/python3 ${./manage}/backups.py --config ${manageConfigFile} run";

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadOnlyPaths = [ "-${cfg.dataDir}" ];
        ReadWritePaths = [ "-${backupRoot}" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    systemd.timers.project-zomboid-backup = lib.mkIf backupEnabled {
      description = "Scheduled Project Zomboid backups";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backup.schedule;
        Persistent = true;
        RandomizedDelaySec = cfg.backup.randomDelaySec;
      };
    };

    # Restore is deliberately a CLI, not an HTTP action: it stops the server,
    # takes a safety archive and replaces world files. A browser button for
    # that is a foot-gun, and the panel's own docs make the same distinction
    # for a server it does not own.
    environment.systemPackages = lib.mkIf backupEnabled [ restoreCommand ];

    networking.firewall.allowedTCPPorts = lib.mkIf (manageEnabled && cfg.manage.openFirewall) [
      cfg.manage.port
    ];

    assertions = lib.mkIf anyEnabled [
      {
        assertion = cfg.backup.keep >= 0;
        message = "services.project-zomboid-servers.backup.keep must be >= 0 (0 disables pruning).";
      }
      {
        # A dashboard with no server is a blank page, not a failure; but a
        # backup timer with no server would silently do nothing forever.
        assertion = !backupEnabled || serverNames != [ ];
        message = "services.project-zomboid-servers.backup.enable is set but no server is enabled.";
      }
    ];
  };
}
