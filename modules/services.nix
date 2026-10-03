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
    concatStringsSep
    unique
    sort
    ;

  cfg = config.services.project-zomboid-servers;
  pz = import ../lib { inherit lib; };

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg.servers;
  resolved = lib.mapAttrs (name: srv: pz.resolveServer cfg.modpacks name srv) enabledServers;
  serverNames = builtins.attrNames resolved;

  unitName = name: "project-zomboid-${name}";
  installUnit = "project-zomboid-install";

  # Every Workshop item any enabled server needs, de-duplicated at EVAL time —
  # two servers sharing a pack must not trigger two downloads of the same item.
  # This is static data, so it belongs in Nix rather than a shell pipeline.
  allWorkshopItems = sort (a: b: a < b) (
    unique (concatMap (srv: srv.workshopItems) (lib.attrValues resolved))
  );

  # PZ looks for mods under <server home>/Zomboid/Workshop/content/108600/<id>.
  # steamcmd populates <serverDir>/steamapps/workshop/content/108600/<id>; we
  # symlink between them so one download serves every server.
  workshopSrc = id: "${cfg.serverDir}/steamapps/workshop/content/108600/${id}";
  workshopDst = name: id: "${cfg.dataDir}/${name}/Zomboid/Workshop/content/108600/${id}";

  consoleFifo = name: "${cfg.runDir}/${name}.fifo";

  # ── Install / update ───────────────────────────────────────────────────────
  # One shared install serves every server: PZ's binaries are identical, only the
  # Zomboid home differs. Also downloads every Workshop item.
  updateScriptText = ''
    # steamcmd resolves relative paths against HOME unless forced; be explicit so
    # an ambient HOME cannot land the install somewhere unexpected.
    export HOME="${cfg.dataDir}"
    mkdir -p "$HOME"

    steamcmd() {
      ${lib.getExe cfg.steamcmd} \
        +force_install_dir "${cfg.serverDir}" \
        +login anonymous "$@" +quit
    }

    steamcmd +app_update ${cfg.package.serverAppId or "380870"} validate

    # `$id` is a SHELL loop variable, so the path is assembled by the shell from
    # a Nix-interpolated root. Calling the `workshopSrc` Nix helper here would
    # make Nix try to evaluate `id` at eval time, where it does not exist.
    workshop_root="${cfg.serverDir}/steamapps/workshop/content/108600"

    for id in ${concatStringsSep " " allWorkshopItems}; do
      if [ -d "$workshop_root/$id" ]; then
        continue
      fi
      echo "project-zomboid: downloading Workshop item $id"
      steamcmd +workshop_download_item 108600 "$id"
    done
  '';

  updateScript = pkgs.writeShellApplication {
    name = "project-zomboid-install";
    runtimeInputs = [ cfg.steamcmd ];
    # Interpolated store paths carry their context automatically, so the
    # string can be passed straight through.
    text = updateScriptText;
  };

  # ── Per-server start-prep ──────────────────────────────────────────────────
  # Lays down the `.ini` (merged in place — PZ's world identity lives in it), a
  # fresh SandboxVars lua (fully ours, so rendered to a store file), and the
  # Workshop mod symlinks.
  mkStartPre =
    name: srv:
    let
      serverHome = "${cfg.dataDir}/${name}";
      ini = "${serverHome}/Zomboid/Server/${srv.serverName}.ini";
      sandbox = "${serverHome}/Zomboid/Server/${srv.serverName}_SandboxVars.lua";
      mergeIni = ../scripts/merge_ini.py;

      # Fully declarative and secret-free, so it can live in the store. This is
      # also what keeps a multi-line value out of the shell script.
      sandboxFile = pkgs.writeText "${srv.serverName}_SandboxVars.lua" (
        pz.renderSandbox {
          settings = srv.sandbox;
        }
      );

      # Values may contain spaces (Map=Muldraugh, KY), so each is shell-escaped;
      # argv needs no newlines, which keeps the whole thing one line.
      iniUpdates = concatMapStringsSep " " lib.escapeShellArg (
        pz.renderIniLines {
          inherit (srv)
            settings
            mods
            workshopItems
            whitelist
            admins
            ;
        }
      );
    in
    pkgs.writeShellApplication {
      name = "${unitName name}-prepare";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.python3
      ];
      text = ''
        server_home="${serverHome}"
        mkdir -p "$server_home/Zomboid/Server" \
                 "$server_home/Zomboid/Workshop/content/108600" \
                 "$server_home/Zomboid/Saves/Multiplayer/${srv.serverName}"

        # Merged, NOT overwritten: Seed / ResetID / LastModified / ServerPlayerID
        # live in this same file, and rewriting it would reset the world on every
        # start. Only the keys below are touched.
        python3 ${mergeIni} "${ini}" \
          ${iniUpdates} \
          ${optionalString (srv.passwordFile != null) "--password-file ${srv.passwordFile}"}

        # SandboxVars is regenerated by PZ itself, so we own it outright.
        cp ${sandboxFile} "${sandbox}"

        # Link each Workshop item from the shared install into this server's
        # home. Redone every start so a newly added mod appears with no manual
        # step and a removed one is unlinked. Symlinks only, so the shared
        # download is never touched.
        ${concatStringsSep "\n" (
          map (id: ''
            src="${workshopSrc id}"
            dst="${workshopDst name id}"
            if [ -d "$src" ]; then
              mkdir -p "$(dirname "$dst")"
              ln -sfn "$src" "$dst"
            elif [ -L "$dst" ]; then
              rm -f "$dst"
            fi
          '') srv.workshopItems
        )}
      '';
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
      exportEnv = lib.concatStringsSep "\n" [
        "export HOME=\"${cfg.dataDir}/${name}\""
        "export PZ_SERVER_DIR=\"${cfg.serverDir}\""
        "export PZ_JVM_OPTS=\"${srv.jvmOpts}\""
      ];
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
              exec ${tmuxCmd} new-session -d ${lib.getExe cfg.package} "${srv.serverName}"
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
              exec ${lib.getExe cfg.package} "${srv.serverName}"
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
          "PZ_SERVER_DIR=${cfg.serverDir}"
          "PZ_JVM_OPTS=${srv.jvmOpts}"
        ];

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
      ${updateScriptText}

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
  config = mkIf cfg.enable {
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
            ExecStart = lib.getExe updateScript;
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
