# modules/services/server.nix
#
# One service plus console socket per enabled server, and the scheduled
# start / idle-stop timers around them.
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
    optional
    optionals
    concatMap
    ;

  ctx = import ./context.nix { inherit config lib pkgs; };
  inherit (ctx)
    cfg
    resolved
    unitName
    installUnit
    consoleFifo
    prepare
    ;

  # The effective JVM flag string for one server: the optional agent first, then
  # jvmOpts. Order matters — a -javaagent must be present at premain, before any
  # mod class can be loaded, and modpacks are free to add -XX flags that assume
  # the agent is already attached.
  #
  # The launcher separates these from the game arguments with `--`, so anything
  # here reaches the JVM. (Before that separator existed, every flag below was
  # silently handed to the game instead.)
  mkJvmOpts =
    srv:
    let
      agent =
        if srv.javaAgent == null then
          ""
        else
          "-javaagent:${srv.javaAgent.jar}"
          + lib.optionalString (srv.javaAgent.args != "") "=${srv.javaAgent.args}"
          + " ";
    in
    "${agent}${srv.jvmOpts}";
  # ── Per-server start-prep ──────────────────────────────────────────────────
  # Delegates to lib/prepare.nix. The dirs come from the unit's Environment
  # (PZ_DATA_DIR / PZ_SERVER_DIR), which is what lets the very same script serve
  # the standalone runner, where the data dir is a runtime flag.
  mkStartPre =
    name: srv:
    prepare.mkPrepScript {
      name = "${unitName name}-prepare";
      server = srv;
      iniBase = prepare.mkIniBase {
        server = srv;
        name = "${srv.serverName}.ini";
      };
      steamAppId = cfg.package.steamAppId or "108600";
      prune = cfg.prune;
    };

  # ── Console backends ───────────────────────────────────────────────────────
  # PZ takes server commands on stdin, so "the console" is fundamentally an
  # fd 0. Backends differ only in how that fd is wired. Yields
  # { serviceConfig, start, stop }.
  mkConsole =
    name: srv:
    let
      ms = srv.managementSystem;
      unit = unitName name;
      # Both backends exec the launcher wrapper with these set. Declared in the
      # unit's Environment too, so ExecStartPre and the web shim see the same
      # values.
      # Parenthesised on purpose. In Nix, `f a [ ... ] ++ b` parses as
      # `f a ([ ... ] ++ b)` — `++` binds TIGHTER than function application — so
      # the concatenation would happen on the LIST and concatStringsSep would
      # then be handed a string, failing with "expected a list but found a
      # string". Passing the concatenated list as one argument is the only
      # unambiguous spelling.
      exportEnv = lib.concatStringsSep "\n" (
        [
          "export HOME=\"${cfg.dataDir}\""
          "export PZ_SERVER_HOME=\"${cfg.dataDir}/${name}\""
          "export PZ_SERVER_DIR=\"${cfg.serverDir}\""
          "export PZ_JVM_OPTS=\"${mkJvmOpts srv}\""
        ]
        ++ lib.optional (srv.adminAccount != null) ''
          export PZ_ADMIN_USERNAME=${lib.escapeShellArg srv.adminAccount.username}
          export PZ_ADMIN_PASSWORD_FILE=${lib.escapeShellArg srv.adminAccount.passwordFile}
        ''
      );

      # `extraArgs` is static Nix data (unlike the admin password), so it is
      # shell-escaped straight into the command line. Shell-escaped rather than
      # interpolated raw: a flag containing a space or a quote must survive, and
      # this string lands in a store script.
      extraArgs = lib.concatMapStringsSep " " lib.escapeShellArg srv.extraArgs;

      # Both backends exec the launcher with these set. Declared in the
      # unit's Environment too, so ExecStartPre and the web shim see the same
      # values.
    in
    if ms.tmux.enable then
      let
        sock = ms.tmux.socketPath name;
        tmuxCmd = "${pkgs.tmux}/bin/tmux -S ${lib.escapeShellArg sock}";
      in
      {
        serviceConfig = {
          Type = "forking";
          # The launcher backgrounds itself under tmux, so systemd needs the real
          # pid from tmux rather than the wrapper's.
          GuessMainPID = true;
        };
        # Store paths, not shell strings: systemd needs an absolute path as the
        # first token of an Exec line.
        start = lib.getExe (
          pkgs.writeShellApplication {
            name = "${unit}-start";
            text = ''
              ${exportEnv}
              exec ${tmuxCmd} new-session -d ${lib.getExe cfg.package} "${srv.serverName}" ${extraArgs}
            '';
          }
        );
        stop = lib.getExe (
          pkgs.writeShellApplication {
            name = "${unit}-stop";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              tmux() { ${tmuxCmd} "$@"; }
              if ! tmux has-session 2>/dev/null; then
                echo "project-zomboid: ${name} is not running under tmux; nothing to stop"
                exit 0
              fi
              # Graceful first: save, then quit. A bare kill loses the world.
              tmux send-keys -t 0 C-u "save" Enter
              sleep 15
              tmux send-keys -t 0 C-u "quit" Enter
              for _ in $(seq 1 60); do
                tmux has-session 2>/dev/null || exit 0
                sleep 1
              done
              echo "project-zomboid: ${name} did not exit in 60s; killing the tmux session"
              tmux kill-session
            '';
          }
        );
      }
    else
      {
        # A real .socket unit owns the FIFO, so there is no ExecStartPre mkfifo
        # dance and no chance of the node having the wrong mode or owner.
        serviceConfig = {
          Type = "simple";
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
        };
        start = lib.getExe (
          pkgs.writeShellApplication {
            name = "${unit}-start";
            text = ''
              ${exportEnv}
              exec ${lib.getExe cfg.package} "${srv.serverName}" ${extraArgs}
            '';
          }
        );
        stop = lib.getExe (
          pkgs.writeShellApplication {
            name = "${unit}-stop";
            text = ''
              fifo="${consoleFifo name}"
              if [ ! -p "$fifo" ]; then
                echo "project-zomboid: no console socket for ${name}; it is already stopped"
                exit 0
              fi
              # Hold the fd open for the whole sequence. Opening per echo would
              # make the server see EOF on stdin and treat the console as closed.
              exec 3>"$fifo"
              printf 'save\n' >&3
              sleep 15
              printf 'quit\n' >&3
              exec 3>&-
            '';
          }
        );
      };

  # ── Per-server service ─────────────────────────────────────────────────────
  mkServerService =
    name: srv:
    let
      unit = unitName name;
      console = mkConsole name srv;
      usesSocket = srv.managementSystem.systemd-socket.enable;
      caps = lib.filterAttrs (_: v: v != null) {
        MemoryMax = srv.hardware.memoryMax;
        MemoryHigh = srv.hardware.memoryHigh;
        MemorySwapMax = srv.hardware.memorySwapMax;
        CPUQuota = srv.hardware.cpuQuota;
        Nice = optional (srv.hardware.nice != null) (toString srv.hardware.nice);
        IOWeight = optional (srv.hardware.ioWeight != null) (toString srv.hardware.ioWeight);
      };
    in
    lib.nameValuePair unit {
      inherit (srv) description;
      # `resolved` already contains only the enabled servers, so no `enable`
      # gate is needed here.
      wantedBy = optionals srv.autoStart [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ optional usesSocket "${unit}.socket"
      ++ optional cfg.updateOnStart "${installUnit}.service";
      wants = [ "network-online.target" ] ++ optional cfg.updateOnStart "${installUnit}.service";
      requires =
        optional usesSocket "${unit}.socket" ++ optional cfg.updateOnStart "${installUnit}.service";

      # Bound crash loops: a server that cannot start (port taken, install
      # missing, OOM) must not restart-storm the host.
      startLimitIntervalSec = cfg.startLimitIntervalSec;
      startLimitBurst = cfg.startLimitBurst;

      serviceConfig = {
        ExecStartPre = lib.getExe (mkStartPre name srv);
        ExecStart = console.start;
        ExecStop = console.stop;

        # PZ does not shut down cleanly on SIGTERM — it needs its own `quit` on
        # stdin, which ExecStop does. SIGCONT is the signal its own docs pair
        # with the fifo, and KillMode=process keeps systemd from also SIGKILLing
        # the steam-run wrapper's children on timeout.
        KillSignal = "SIGCONT";
        KillMode = "process";
        # Saving on shutdown can take up to a minute on a large world.
        TimeoutStopSec = "90s";

        Restart = srv.restart;
        RestartSec = "5s";

        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.serverDir;
        Environment = [
          # Steam's cached login lives under the SERVICE USER's home
          # (<dataDir>/.local/share/Steam), so HOME stays the data dir. PZ's own
          # `Zomboid` directory is per-server and is pinned separately via
          # PZ_SERVER_HOME -> -Duser.home in the launcher.
          "HOME=${cfg.dataDir}"
          "PZ_SERVER_HOME=${cfg.dataDir}/${name}"
          # Java derives its filename encoding from the process locale, and a
          # systemd service gets none (no LANG/LC_ALL — NixOS sets neither), so
          # the JVM falls back to ANSI_X3.4-1968. With that encoding it throws
          # `java.nio.file.InvalidPathException: Malformed input or input
          # contains unmappable characters` for any mod folder whose name is not
          # ASCII — three Workshop items in the viewpoint pack ship one — and
          # aborts mod loading. `C.UTF-8` is built into glibc >= 2.35, so this
          # needs no `i18n.supportedLocales`, and it keeps C numeric formatting.
          "LANG=C.UTF-8"
          "LC_ALL=C.UTF-8"
          # Read by lib/prepare.nix's prep script, which is shared with the
          # standalone runner.
          "PZ_DATA_DIR=${cfg.dataDir}"
          "PZ_SERVER_DIR=${cfg.serverDir}"
          "PZ_WORKSHOP_DIR=${cfg.workshopDir}"
          "PZ_SERVER_NAME=${srv.serverName}"
          # Quoted so systemd keeps this as ONE assignment. Without the quotes
          # its parser splits the value on whitespace and logs
          # `Invalid environment assignment, ignoring: -Xms4G` for every flag
          # after the first — which is every jvmOpts, including the default.
          "PZ_JVM_OPTS=\"${mkJvmOpts srv}\""
        ]
        # The admin login. Only the USERNAME and the secret's PATH — never the
        # password itself, which the launcher reads from the file at start. A
        # path in a world-readable unit file discloses nothing; a value would
        # undo the whole point of secretFiles.
        # `optional`, not `optionalAttrs`: systemd.serviceConfig.Environment is a
        # list of strings, so this has to extend the list rather than an attrset.
        ++ lib.optional (srv.adminAccount != null) "PZ_ADMIN_USERNAME=${srv.adminAccount.username}"
        ++ lib.optional (
          srv.adminAccount != null
        ) "PZ_ADMIN_PASSWORD_FILE=${srv.adminAccount.passwordFile}";

        # Hardening, chosen to stay compatible with steam-run's bwrap user
        # namespace: PrivateUsers/PrivateDevices break the FHS shim, and the
        # install plus the data dir must stay writable under ProtectSystem.
        #
        # `RestrictNamespaces` and `CapabilityBoundingSet=""` are deliberately
        # NOT set here either: bwrap creates its own user/mount namespace and
        # needs the capabilities that come with it, so restricting either one
        # produces a server that fails at startup with no useful error. The
        # directives below are the ones that do not touch that path.
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.dataDir
          cfg.serverDir
        ];
        ProtectHome = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        UMask = "0027";
      }
      // console.serviceConfig
      // caps
      // srv.extraServiceConfig;
    };

  # ── Console sockets ────────────────────────────────────────────────────────
  mkConsoleSocket =
    name: srv:
    lib.nameValuePair (unitName name) {
      wantedBy = [ "sockets.target" ];
      # `Requires=` on a socket EAGERLY starts the paired service whenever the
      # socket starts, and sockets.target pulls the socket in at boot — so an
      # unconditional `requires` made `autoStart = false` meaningless: the server
      # came up anyway (verified: `systemctl restart <unit>.socket` starts the
      # service). Keep the dependency only when autoStart is on. Without it the
      # implicit same-name socket activation still brings the service up on the
      # first write to the console FIFO, which is what autoStart = false should
      # mean.
      requires = lib.optional srv.autoStart "${unitName name}.service";
      partOf = [ "${unitName name}.service" ];
      socketConfig = {
        ListenFIFO = consoleFifo name;
        SocketMode = "0660";
        SocketUser = cfg.user;
        SocketGroup = cfg.group;
        # The fifo is derived state, not user state: it must not outlive a stop,
        # or the next start inherits a stale node with no reader.
        RemoveOnStop = true;
        FlushPending = true;
      };
    };

  # ── Scheduled start / idle stop ────────────────────────────────────────────
  # Both are timers around the existing server unit. The start timer activates
  # the service directly (`Unit=`), so it needs no companion service of its own.
  # The idle timer runs a small root oneshot because stopping a system unit is
  # privileged; the script itself only reads the rendered `.ini` and talks to
  # RCON on loopback.
  startTimerServers = lib.filterAttrs (_: srv: srv.schedule.start != [ ]) resolved;
  idleStopServers = lib.filterAttrs (_: srv: srv.idleStop.enable) resolved;

  mkStartTimer =
    name: srv:
    lib.nameValuePair "${unitName name}-start" {
      description = "Start ${srv.description} on schedule";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "${unitName name}.service";
        OnCalendar = srv.schedule.start;
        Persistent = srv.schedule.persistent;
      };
    };

  mkIdleStopService =
    name: srv:
    let
      unit = unitName name;
      ini = "${cfg.dataDir}/${name}/Zomboid/Server/${srv.serverName}.ini";
      state = "${cfg.runDir}/${name}.idle-since";
    in
    lib.nameValuePair "${unit}-idle" {
      description = "Stop ${srv.description} after it has been empty for ${srv.idleStop.timeout}";
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pkgs.python3}/bin/python3 ${../manage}/idle_stop.py --unit ${unit} --ini ${ini} --state ${state} --timeout ${srv.idleStop.timeout}";
        # PZ's own stop path sends `save`, waits 15s, then `quit`; the server
        # unit allows up to 90s for that. Give the oneshot room to wait for it.
        TimeoutStartSec = "180s";
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        # The script talks to systemd over the private socket and parses the
        # rendered `.ini`; it never needs a capability of its own.
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        ReadWritePaths = [ cfg.runDir ];
      };
    };

  mkIdleStopTimer =
    name: _srv:
    lib.nameValuePair "${unitName name}-idle" {
      description = "Timer for ${unitName name} idle shutdown";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "${unitName name}-idle.service";
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
        AccuracySec = "15s";
      };
    };
in
{
  config = mkIf (cfg.enable && cfg.package != null) {
    systemd.services = mkMerge [
      (lib.mapAttrs' mkServerService resolved)
      # Idle shutdown. One root oneshot per server; the matching timer is in
      # `systemd.timers` below. Defined here (not as a `.timer`-activated
      # anonymous unit) so `systemctl cat` shows exactly what will run.
      (lib.mapAttrs' mkIdleStopService idleStopServers)
    ];

    # Console FIFOs are `systemd.sockets` units, NOT `systemd.services`:
    # ListenFIFO/SocketMode are socketConfig options, and putting them on a
    # service fails with "The option systemd.services.<name>.socketConfig does
    # not exist".
    # Filtered, not merely disabled: a server on the tmux backend should have NO
    # console socket unit declared at all, rather than an inert one that still
    # shows up in `systemctl list-unit-files` and in any config that reads
    # `systemd.sockets`.
    # The `_:` adapter makes the arity explicit — see the note on the web
    # consoles below for why partial application here is a trap.
    systemd.sockets = lib.mapAttrs' (name: srv: mkConsoleSocket name srv) (
      lib.filterAttrs (_: srv: srv.managementSystem.systemd-socket.enable) resolved
    );

    systemd.timers = mkMerge [
      # Scheduled starts. `Unit=` points at the server service, which the
      # timer can activate even though no `project-zomboid-<name>-start`
      # service exists.
      (lib.mapAttrs' mkStartTimer startTimerServers)

      (lib.mapAttrs' mkIdleStopTimer idleStopServers)
    ];

    # The console fifos live in a tmpfs-backed directory created by tmpfiles,
    # because the .socket unit needs the directory to exist before any service
    # runs.
    systemd.tmpfiles.rules = [ "d '${cfg.runDir}' 0755 ${cfg.user} ${cfg.group} - -" ];

    networking.firewall.allowedTCPPorts = concatMap (
      srv: optional (srv.openRconFirewall && srv.rconPort != 0) srv.rconPort
    ) (lib.attrValues resolved);
  };
}
