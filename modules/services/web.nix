# modules/services/web.nix
#
# The ttyd console per server that asked for `webConsole`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    optionalString
    ;

  ctx = import ./context.nix { inherit config lib pkgs; };
  inherit (ctx)
    cfg
    unitName
    consoleFifo
    webServers
    webPort
    ;

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
              # No sudo: config.nix grants this user a polkit rule for
              # manage-units on project-zomboid-* , which systemctl consults
              # over D-Bus on its own. A `sudo -n` here would be refused outright
              # on hosts that set security.sudo.execWheelOnly.
              ${pkgs.systemd}/bin/systemctl "''${line#.}" "$svc" 2>&1
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
      unit = unitName name;
    in
    lib.nameValuePair "${unit}-web" {
      description = "Project Zomboid web console: ${name}";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.systemd
        pkgs.coreutils
      ];
      serviceConfig = {
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "${unit}-web-launcher";
            runtimeInputs = [
              pkgs.ttyd
              pkgs.coreutils
            ];
            text = ''
              ${
                if needsAuth then
                  ''
                    # Read here, never interpolated into the unit, so the secret is
                    # not visible in `systemctl cat`. It IS visible in the process
                    # list, because ttyd has no credential-file option; see the
                    # warning in modules/config.nix and the web.username option.
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
                ${lib.getExe (mkWebShim name)}
            '';
          }
        );
        User = cfg.web.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "2s";

        # ttyd is a terminal server, not a shell: it needs no devices beyond
        # its own pty and no filesystem beyond the store and the FIFO. The
        # defaults below are deliberately conservative; PrivateDevices is left
        # out because it can remove /dev/ptmx, and the service must keep the
        # ability to open a pty.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        UMask = "0027";
        RestrictNamespaces = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        ProtectProc = "invisible";
        ProcSubset = "pid";
        CapabilityBoundingSet = "";
      };
    };
in
{
  config = mkIf (cfg.enable && cfg.package != null && cfg.web.enable) {
    systemd.services = lib.mapAttrs' (name: _: mkWebService name) webServers;

    networking.firewall.allowedTCPPorts = lib.optionals cfg.web.openFirewall (
      map (name: webPort name) (lib.attrNames webServers)
    );
  };
}
