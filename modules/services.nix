# modules/services.nix
#
# The systemd units: the shared install/update, one service (+ console socket)
# per server, and optional ttyd web consoles.
#
# Design notes that are easy to get wrong and are therefore load-bearing here:
#
#   * `ExecStart`/`ExecStop`/`ExecStartPre` are ALWAYS a store path from
#     `pkgs.writeShellApplication` + `lib.getExe`. systemd requires an absolute
#     path as the first token of an Exec line, so a bare multi-line shell string
#     (which an earlier draft of this module used for ExecStartPre) fails
#     203/EXEC. writeShellApplication also brings `set -euo pipefail` and a
#     shellcheck pass at build time.
#
#   * `Requires=`/`After=` only ever name units that THIS module defines. A
#     reference to a non-existent unit makes `systemctl start` fail outright, so
#     the install unit below lives in the same file as the servers that require
#     it.
#
#   * Nothing interpolates a multi-line string into the middle of a Nix `''`
#     block. Nix strips the *minimum* indentation of a multiline string, so an
#     interpolated value carrying its own newlines silently de-indents the rest
#     of the block and breaks any heredoc terminator. Multi-line content is
#     therefore rendered to a store file with `pkgs.writeText` and `cp`'d, and
#     every argv value is shell-escaped and passed on a single line.
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
    optionalString
    concatMap
    concatMapStringsSep
    unique
    sort
    ;

  cfg = config.services.project-zomboid-servers;
  pz = import ../lib { inherit lib; };

  # The SAME prep/install scripts the standalone runner uses
  # (`nix run .#pz-dedicated-server`). One implementation, so a server cannot
  # behave one way under systemd and another under `nix run` — and so the `.ini`
  # merge that preserves world identity is written once.
  prepare = import ../lib/prepare.nix {
    inherit lib pkgs pz;
  };

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg.servers;
  resolved = lib.mapAttrs (name: srv: pz.resolveServer cfg.modpacks name srv) enabledServers;
  serverNames = builtins.attrNames resolved;

  unitName = name: "project-zomboid-${name}";
  installUnit = "project-zomboid-install";

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

  # Every Workshop item any enabled server needs, de-duplicated at EVAL time —
  # two servers sharing a pack must not trigger two downloads of the same item.
  # This is static data, so it belongs in Nix rather than a shell pipeline.
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

  # The Workshop symlinking and the console FIFO path now live in
  # lib/prepare.nix (shared with the standalone runner) and below respectively.

  consoleFifo = name: "${cfg.runDir}/${name}.fifo";

  # ── Install / update ───────────────────────────────────────────────────────
  # One shared install serves every server: PZ's binaries are identical, only the
  # Zomboid home differs. De-duplicated at eval time across all servers.
  installScript = prepare.mkInstallScript {
    steamcmd = cfg.steamcmd;
    serverAppId = cfg.package.serverAppId or "380870";
    steamAppId = cfg.package.steamAppId or "108600";
    workshopItems = allWorkshopItems;
    betaBranch = installBetaBranch;
  };

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
          "export HOME=\"${cfg.dataDir}/${name}\""
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
          "HOME=${cfg.dataDir}/${name}"
          # Read by lib/prepare.nix's prep script, which is shared with the
          # standalone runner.
          "PZ_DATA_DIR=${cfg.dataDir}"
          "PZ_SERVER_DIR=${cfg.serverDir}"
          "PZ_SERVER_NAME=${srv.serverName}"
          "PZ_JVM_OPTS=${mkJvmOpts srv}"
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
        UMask = "0027";
      }
      // console.serviceConfig
      // caps
      // srv.extraServiceConfig;
    };

  # ── Console sockets ────────────────────────────────────────────────────────
  mkConsoleSocket =
    name:
    lib.nameValuePair (unitName name) {
      wantedBy = [ "sockets.target" ];
      requires = [ "${unitName name}.service" ];
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

  # ── Web consoles ───────────────────────────────────────────────────────────
  webServers = lib.filterAttrs (_: srv: cfg.web.enable && srv.webConsole) resolved;

  # Ports are assigned in sorted server order, so they stay stable as long as
  # servers are not renamed.
  webPort =
    name:
    if resolved.${name}.port != null then
      resolved.${name}.port
    else
      cfg.web.portBase + (lib.length (builtins.filter (n: n < name) (builtins.attrNames webServers)));

  mkWebShim =
    name:
    pkgs.writeShellApplication {
      name = "${unitName name}-web";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.systemd
      ];
      text = ''
        fifo="${consoleFifo name}"
        log="${cfg.dataDir}/${name}/Zomboid/Logs/server.txt"
        svc="${unitName name}"

        echo "== Project Zomboid console: ${name} =="
        echo "Type a command to send it to the server."
        echo "Dot-commands: .status .start .stop .restart .help"

        tail -F -n 100 "$log" 2>/dev/null &
        tail_pid=$!
        trap 'kill "$tail_pid" 2>/dev/null || true' EXIT

        while IFS= read -r line; do
          case "$line" in
            .status)
              ${pkgs.systemd}/bin/systemctl status "$svc" --no-pager 2>&1 | head -40
              ;;
            .start|.stop|.restart)
              # Scoped, password-less sudo for exactly these verbs and this
              # unit is granted by config.nix.
              sudo -n ${pkgs.systemd}/bin/systemctl "''${line#.}" "$svc" 2>&1
              ;;
            .help)
              echo "commands: .status .start .stop .restart"
              ;;
            "")
              ;;
            *)
              if [ -p "$fifo" ]; then
                printf '%s\n' "$line" > "$fifo"
              else
                echo "[${name} is not running — start it first]"
              fi
              ;;
          esac
        done
      '';
    };

  mkWebService =
    name:
    let
      needsAuth = cfg.web.username != null && cfg.web.passwordFile != null;
    in
    lib.nameValuePair "project-zomboid-${name}-web" {
      description = "Project Zomboid web console: ${name}";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.sudo
        pkgs.systemd
        pkgs.coreutils
      ];
      serviceConfig = {
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "project-zomboid-${name}-web-launcher";
            runtimeInputs = [
              pkgs.ttyd
              pkgs.coreutils
            ];
            text = ''
              ${
                if needsAuth then
                  ''
                    # Read here, never interpolated into the unit, so the secret is
                    # not visible in `systemctl cat`.
                    password="$(cat "${cfg.web.passwordFile}")"
                  ''
                else
                  ""
              }
              exec ttyd \
                --port ${toString (webPort name)} \
                --interface ${cfg.web.bind} \
                --writable \
                --max-clients 2 \
                --check-origin \
                ${optionalString needsAuth "--credential \"${cfg.web.username}:$password\""} \
                ${mkWebShim name}
            '';
          }
        );
        User = cfg.web.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

  mkUpdateTimer = pkgs.writeShellApplication {
    name = "project-zomboid-update";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      ${installScript}/bin/project-zomboid-install

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
  # `cfg.package != null` as well as `cfg.enable`, and the reason is diagnostic.
  #
  # Every unit below reaches the launcher through `lib.getExe cfg.package`, so
  # with `package` unset the evaluation dies INSIDE this file with
  #
  #   lib.meta.getExe': The first argument is of type null, but it should be a
  #   derivation instead
  #
  # — thrown while building `systemd.services.<name>.serviceConfig`, which is
  # evaluated before anyone can read `config.assertions`. So the module's own
  # assertion explaining the fix never gets a chance to appear.
  #
  # Defining no units at all when `package` is missing lets evaluation finish, so
  # the one message that says what to do is the one that gets reported. The
  # resulting state (units absent) is already what the config asked for.
  config = mkIf (cfg.enable && cfg.package != null) {
    # One place for every unit, so nothing can shadow or duplicate.
    systemd.services = mkMerge [
      # The install unit the servers require. Defined HERE, in the same file, so
      # `Requires=` can never dangle.
      (mkIf cfg.updateOnStart {
        "${installUnit}" = {
          description = "Project Zomboid install/update (steamcmd app 380870 + Workshop mods)";
          wantedBy = [ "multi-user.target" ];
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
            ];
            ExecStart = lib.getExe installScript;
            # A first install pulls the whole game over the network.
            TimeoutStartSec = "45min";
          };
        };
      })

      (lib.mapAttrs' mkServerService resolved)

      # Timer-driven update. Separate from the boot-time install unit because
      # that unit's RemainAfterExit would make a second ExecStart a no-op.
      (mkIf (cfg.updateSchedule != null) {
        "project-zomboid-update" = {
          description = "Project Zomboid update on a schedule, restarting running servers";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Environment = [
              "PZ_DATA_DIR=${cfg.dataDir}"
              "PZ_SERVER_DIR=${cfg.serverDir}"
            ];
            ExecStart = lib.getExe mkUpdateTimer;
            TimeoutStartSec = "45min";
          };
        };
      })

      # `lib.mapAttrs'` (not `map`): it turns the { name, value; } pairs into a
      # real attrset. `mkMerge` cannot merge a LIST of pairs, and passing one
      # fails with "A definition for option `systemd.services' is not of type
      # `attribute set of (submodule)'".
      # The `_:` adapter makes the arity explicit: `mapAttrs'` passes
      # (name, value) but the builder only needs the name. Relying on partial
      # application here instead produced an inscrutable "attempt to call
      # something which is not a function but a set" from `listToAttrs`.
      (mkIf cfg.web.enable (lib.mapAttrs' (name: _: mkWebService name) webServers))
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
    systemd.sockets = lib.mapAttrs' (name: _: mkConsoleSocket name) (
      lib.filterAttrs (_: srv: srv.managementSystem.systemd-socket.enable) resolved
    );

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

    # The console fifos live in a tmpfs-backed directory created by tmpfiles,
    # because the .socket unit needs the directory to exist before any service
    # runs.
    systemd.tmpfiles.rules = [ "d '${cfg.runDir}' 0755 ${cfg.user} ${cfg.group} - -" ];

    # ── Firewall ────────────────────────────────────────────────────────────
    networking.firewall.allowedUDPPorts = concatMap (
      srv: optionals srv.openFirewall (pz.udpPortsOf srv)
    ) (lib.attrValues resolved);

    # `lib.optionals`, not `mkIf`: mkIf yields a `{ _type = "if"; … }` set that is
    # only valid as a whole option definition, so using it as an operand of `++`
    # fails with "expected a list but found a set".
    networking.firewall.allowedTCPPorts =
      concatMap (srv: optional (srv.rconPort != 0) srv.rconPort) (lib.attrValues resolved)
      ++ lib.optionals cfg.web.openFirewall (map (name: webPort name) (builtins.attrNames webServers));
  };
}
