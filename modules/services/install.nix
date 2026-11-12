# modules/services/install.nix
#
# The shared steamcmd install and the timer that restarts it.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkMerge
    optionals
    concatMap
    concatMapStringsSep
    unique
    sort
    ;

  ctx = import ./context.nix { inherit config lib pkgs; };
  inherit (ctx)
    cfg
    resolved
    serverNames
    unitName
    installUnit
    prepare
    ;

  # Every Workshop item the DEDICATED install unit must keep downloaded,
  # de-duplicated at EVAL time — two servers sharing a pack must not trigger two
  # downloads of the same item. This is static data, so it belongs in Nix rather
  # than a shell pipeline.
  #
  # Client hosts are deliberately EXCLUDED. A client host downloads its own mods
  # through Steam when the game's Host button runs, into the library that owns
  # the PZ install; it never reads this install. Including its ids here was the
  # last coupling between the two paths and made a client-only configuration
  # fetch content no unit on the host would ever use.
  allWorkshopItems = sort (a: b: a < b) (
    unique (concatMap (srv: srv.workshopItems) (lib.attrValues resolved))
  );

  # One install serves one branch, so the shared install unit takes the first
  # server's choice. config.nix asserts that they all agree, so "first" is never
  # "arbitrary" — it just has to be deterministic.
  installBetaBranch =
    let
      branches = unique (map (srv: srv.betaBranch) (lib.attrValues resolved));
    in
    if branches == [ ] then null else lib.head branches;
  # ── Install / update ───────────────────────────────────────────────────────
  # One shared install serves every server: PZ's binaries are identical, only the
  # Zomboid home differs. De-duplicated at eval time across all servers.
  #
  # Workshop id -> title, so a failed download can name the mod rather than only
  # its number. Drawn from the catalogue and any inline server mods; a title is
  # cosmetic, so a missing one is harmless.
  itemTitles = builtins.listToAttrs (
    map (m: lib.nameValuePair m.id (if m.title == null then "" else m.title)) (
      lib.concatMap (p: p.workshopMods) (builtins.attrValues cfg.modpacks)
      ++ lib.concatMap (s: s.workshopMods) (builtins.attrValues cfg.servers)
    )
  );

  installScript = prepare.mkInstallScript {
    steamcmd = cfg.steamcmd;
    serverAppId = cfg.package.serverAppId or "380870";
    steamAppId = cfg.package.steamAppId or "108600";
    workshopItems = allWorkshopItems;
    betaBranch = installBetaBranch;
    login = cfg.steamLogin;
    prune = cfg.prune;
    failOnMissingMods = cfg.failOnMissingMods;
    inherit itemTitles;
  };
  mkUpdateTimer = pkgs.writeShellApplication {
    name = "project-zomboid-update";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      # Restart the INSTALL UNIT rather than running the store script directly.
      # The updater is root (it needs `systemctl try-restart`), while the
      # downloader must run as the service user: running steamcmd as root
      # leaves root-owned files in dataDir/serverDir and a root-owned cached
      # Steam login, which the next server start cannot use.
      ${pkgs.systemd}/bin/systemctl restart ${installUnit}.service

      ${
        if cfg.restartAfterUpdate then
          # try-restart, not restart: a deliberately stopped server should
          # stay stopped across an update. Built here rather than with a shell
          # `for`, because `name` would then be a shell variable while
          # `unitName` is Nix and Nix evaluates it at eval time.
          concatMapStringsSep "\n" (name: ''
            ${pkgs.systemd}/bin/systemctl try-restart "${unitName name}.service" || true
          '') serverNames
        else
          ""
      }
    '';
  };
in
{
  config = mkIf (cfg.enable && cfg.package != null) {
    systemd.services = mkMerge [
      (mkIf (cfg.updateOnStart || cfg.updateSchedule != null) {
        "${installUnit}" = {
          description = "Project Zomboid install/update (steamcmd app 380870 + Workshop mods)";
          wantedBy = optionals cfg.updateOnStart [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            # RemainAfterExit so N servers requiring this unit trigger ONE
            # install at boot rather than N.
            RemainAfterExit = true;
            User = cfg.user;
            Group = cfg.group;
            WorkingDirectory = cfg.dataDir;
            # lib/prepare.nix takes the directories from the environment, which is
            # what lets the standalone runner reuse the same script with a
            # runtime --data-dir.
            Environment = [
              "PZ_DATA_DIR=${cfg.dataDir}"
              "PZ_SERVER_DIR=${cfg.serverDir}"
              "PZ_WORKSHOP_DIR=${cfg.workshopDir}"
            ];
            ExecStart = lib.getExe installScript;
            # A first install pulls the whole game plus every Workshop item
            # over the network. 45min was not enough for a 438-item pack on a
            # flaky link (2026-11-11: it timed out with 101 items left). The
            # script now downloads in batches of 20 with three passes, so this
            # is a generous safety net rather than the expected duration.
            TimeoutStartSec = "2h";

            # The downloader is network-facing and only owns these trees.
            # Keep the same UMask as the server units so a file it creates is
            # readable by the service group, never world-readable.
            #
            # `LockPersonality` and `SystemCallArchitectures` are left off on
            # purpose: steamcmd is a 32-bit binary, and locking the execution
            # domain or personality makes it fail to start. The rest of the
            # sandbox does not depend on either.
            UMask = "0027";
            PrivateTmp = true;
            ProtectSystem = "strict";
            ReadWritePaths = [
              cfg.dataDir
              cfg.serverDir
              cfg.workshopDir
            ];
            ProtectHome = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            NoNewPrivileges = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
          };
        };
      })
      # Timer-driven update. Separate from the boot-time install unit because
      # that unit's RemainAfterExit would make a second ExecStart a no-op.
      (mkIf (cfg.updateSchedule != null) {
        "project-zomboid-update" = {
          description = "Project Zomboid update on a schedule, restarting running servers";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            # Root only for `systemctl restart` / `try-restart`; the install
            # itself runs in project-zomboid-install.service as cfg.user.
            User = "root";
            ExecStart = lib.getExe mkUpdateTimer;
            TimeoutStartSec = "2h";

            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            LockPersonality = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            # Root, but only to ask systemd to restart units: no capability
            # beyond the D-Bus/private-socket connection is needed.
            CapabilityBoundingSet = "";
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
      })
    ];

    systemd.timers = mkIf (cfg.updateSchedule != null) {
      "project-zomboid-update" = {
        description = "Timer for Project Zomboid server updates";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.updateSchedule;
          Persistent = true;
        };
      };
    };
  };
}
