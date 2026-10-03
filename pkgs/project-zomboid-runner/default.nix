# pkgs/project-zomboid-runner/default.nix
#
# `pz-dedicated-server` — run a Project Zomboid dedicated server without a NixOS
# host: local play, trying a modpack out, or testing the catalogue.
#
#   nix run github:you/nixos-projectzomboid-servers#pz-dedicated-server -- myserver
#   nix run github:you/nixos-projectzomboid-servers#pz-vanilla-plus   -- myserver
#
# It is the SAME machinery the NixOS module uses, sharing one implementation via
# lib/prepare.nix: the install/validate step, the `.ini` merge, the SandboxVars
# render and the Workshop symlinks. Only the supervision differs — the module gets
# that from systemd (a `.socket` unit owning a FIFO, `ExecStop` writing `quit`),
# this from a small shell supervisor.
#
# WHY THE PACK IS A NIX-SIDE ARGUMENT, NOT A RUNTIME FLAG
# -------------------------------------------------------
# Resolving a pack means merging its defaults, the module-owned keys and inline
# overrides — all Nix values — and rendering `Key=value` lines. That happens at
# eval time, so `--modpack` cannot be a runtime flag without shipping the whole
# catalogue into the script and reimplementing the merge in shell. Instead the
# flake exposes one app per pack (`pz-<pack>`), so the choice stays declarative.
# Runtime flags still cover everything that genuinely is runtime: paths, ports,
# heap, and ad-hoc `Key=value` overrides.
{
  lib,
  pkgs,
  stdenvNoCC,
  project-zomboid-server,
  steamcmd,
  pz-prepare,
  resolvedServer,
  modpack ? null,
}:

let
  # De-duplicated at eval time: two servers sharing a pack must not trigger two
  # downloads of the same Workshop item.
  workshopItems = lib.unique resolvedServer.workshopItems;

  iniBase = pz-prepare.mkIniBase {
    server = resolvedServer;
    name = "${resolvedServer.serverName}.ini";
  };

  prepScript = pz-prepare.mkPrepScript {
    server = resolvedServer;
    inherit iniBase;
    steamAppId = project-zomboid-server.steamAppId;
  };

  installScript = pz-prepare.mkInstallScript {
    steamcmd = steamcmd;
    serverAppId = project-zomboid-server.serverAppId;
    steamAppId = project-zomboid-server.steamAppId;
    workshopItems = workshopItems;
  };
in
stdenvNoCC.mkDerivation {
  pname = "project-zomboid-runner";
  version = "0.1.0";

  dontUnpack = true;
  dontBuild = true;
  dontConfigure = true;
  # NOT `dontInstall = true`: that makes stdenv skip installPhase entirely, so the
  # build would "succeed" with an empty $out and the runner would never exist.

  # The launcher itself: fixes steam_appid.txt and injects the JVM flags ahead of
  # the vendor script, then execs it so the JVM inherits our PID.
  launcher = project-zomboid-server;

  passthru = {
    inherit resolvedServer workshopItems;
    inherit modpack;
  };

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"

    cat > "$out/bin/pz-dedicated-server" <<'PZ_EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail

    # ── Defaults, overridable by flags ──────────────────────────────────────
    server_name=""
    data_dir="$PWD/pz-data"
    server_dir=""
    port="${toString resolvedServer.defaultPort}"
    udp_port="${toString resolvedServer.udpPort}"
    rcon_port="${toString resolvedServer.rconPort}"
    max_players="${toString resolvedServer.settings.maxPlayers}"
    map_name="${resolvedServer.map}"
    jvm_opts="${resolvedServer.jvmOpts}"
    do_install=1
    print_only=0
    declare -a overrides=()

    # `modpack` is a NIX binding. Assigned here so the shell has a real variable
    # to print and branch on — reading `${"modpack:-none"}` directly in the script
    # would silently expand to "none" every time.
    modpack=${lib.escapeShellArg (if modpack == null then "" else modpack)}

    usage() {
      cat <<'USAGE'
    pz-dedicated-server — run a Project Zomboid dedicated server

    Validates the steamcmd install, downloads the modpack's Workshop mods,
    writes the server config, then runs the server with your terminal as the
    console. Ctrl-C (or end-of-input) saves and quits cleanly.

    Usage: pz-dedicated-server [options] <server-name>

    Options:
      --data-dir PATH      base directory        (default: $PWD/pz-data)
      --server-dir PATH    steamcmd install      (default: <data-dir>/server)
      --port N             game port             (default: ${toString resolvedServer.defaultPort})
      --udp-port N         direct-connection UDP (default: ${toString resolvedServer.udpPort})
      --rcon-port N        RCON TCP port, 0=off  (default: ${toString resolvedServer.rconPort})
      --max-players N      (default: ${toString resolvedServer.settings.maxPlayers})
      --map NAME           (default: ${resolvedServer.map})
      --jvm-opts "FLAGS"   (default: ${resolvedServer.jvmOpts})
      --set KEY=VALUE      extra .ini key, repeatable; wins over the modpack
      --no-install         skip the steamcmd validate (much faster restarts)
      --print-config       write the config, print it, exit — needs no game files
      -h, --help           this message
    USAGE
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --data-dir)   data_dir="$2";   shift 2 ;;
        --server-dir) server_dir="$2"; shift 2 ;;
        --port)       port="$2";       shift 2 ;;
        --udp-port)   udp_port="$2";   shift 2 ;;
        --rcon-port)  rcon_port="$2";  shift 2 ;;
        --max-players) max_players="$2"; shift 2 ;;
        --map)        map_name="$2";   shift 2 ;;
        --jvm-opts)   jvm_opts="$2";   shift 2 ;;
        --set)        overrides+=("$2"); shift 2 ;;
        --no-install) do_install=0;    shift ;;
        --print-config) print_only=1;  shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; [ "$#" -gt 0 ] && server_name="$1"; shift ;;
        -*)           echo "pz-dedicated-server: unknown option: $1" >&2
                      echo "try --help" >&2; exit 2 ;;
        *)            server_name="$1"; shift ;;
      esac
    done

    if [ -z "$server_name" ]; then
      echo "pz-dedicated-server: a server name is required" >&2
      echo >&2
      usage >&2
      exit 2
    fi

    : "''${server_dir:=$data_dir/server}"
    export PZ_DATA_DIR="$data_dir"
    export PZ_SERVER_DIR="$server_dir"
    # The prep script is shared with the NixOS module and reads the server name
    # from here, because it is a runtime argument rather than Nix data.
    export PZ_SERVER_NAME="$server_name"

    printf 'project-zomboid: server    %s\n' "$server_name"
    printf 'project-zomboid: modpack   %s\n' "''${modpack:-none}"
    printf 'project-zomboid: data-dir  %s\n' "$PZ_DATA_DIR"
    printf 'project-zomboid: install   %s\n' "$PZ_SERVER_DIR"
    printf 'project-zomboid: ports     %s (udp) / %s (udp) / %s (rcon)\n' \
      "$port" "$udp_port" "$rcon_port"

    mkdir -p "$PZ_DATA_DIR"

    # ── Install ──────────────────────────────────────────────────────────────
    if [ "$do_install" -eq 1 ]; then
      # First run downloads several GB. --no-install skips it entirely.
      ${installScript}/bin/project-zomboid-install
    fi

    # ── Config ───────────────────────────────────────────────────────────────
    # The shared prep script: merges the Nix-rendered base config into the
    # server's .ini without touching PZ's world-identity keys, writes
    # SandboxVars, and links the Workshop mods. Runtime flags are layered on top
    # as Key=value overrides, which is why a different --port needs no rebuild.
    # PublicName is one of the overrides because it is derived from the Nix-side
    # server name, which is a fixed placeholder in this derivation — the real one
    # is this runtime argument.
    #
    # NOTE no comments inside the command itself: a `#` line within a `\`
    # continuation is a SHELL comment and swallows the rest of the command.
    ${prepScript}/bin/project-zomboid-prepare \
      "DefaultPort=$port" \
      "UDPPort=$udp_port" \
      "RCONPort=$rcon_port" \
      "MaxPlayers=$max_players" \
      "Map=$map_name" \
      "PublicName=$server_name" \
      ''${overrides[@]+"''${overrides[@]}"}

    ini="$PZ_DATA_DIR/$server_name/Zomboid/Server/$server_name.ini"
    sandbox="$PZ_DATA_DIR/$server_name/Zomboid/Server/''${server_name}_SandboxVars.lua"

    if [ "$print_only" -eq 1 ]; then
      printf '\n== %s ==\n' "$ini"
      cat "$ini"
      printf '\n== %s ==\n' "$sandbox"
      cat "$sandbox"
      exit 0
    fi

    # Checked HERE, after --print-config, so that inspecting what config a modpack
    # produces needs no multi-gigabyte download.
    if [ ! -x "$PZ_SERVER_DIR/start-server.sh" ]; then
      echo "pz-dedicated-server: $PZ_SERVER_DIR/start-server.sh is missing — cannot start." >&2
      echo "  run without --no-install to fetch the dedicated server." >&2
      exit 1
    fi

    # ── Supervise ────────────────────────────────────────────────────────────
    # The server reads console commands from stdin. Give it a FIFO and hold the
    # write end open for the whole session: opening it per command would hand the
    # server EOF between lines and it would treat the console as closed. This is
    # the same problem the module solves with a systemd .socket unit.
    run_dir="''${XDG_RUNTIME_DIR:-/tmp}"
    ctl="$run_dir/pz-ctl-''$$"
    rm -f "$ctl"
    mkfifo -m 0600 "$ctl"
    # shellcheck disable=SC2064
    trap 'rm -f "$ctl"' EXIT

    printf 'project-zomboid: starting %s\n' "$server_name"
    printf 'project-zomboid: logs %s\n' "$PZ_DATA_DIR/$server_name/Zomboid/Logs/server.txt"
    printf 'project-zomboid: type server commands; Ctrl-C or Ctrl-D to save and quit\n'

    ${lib.getExe project-zomboid-server} "$server_name" \
      < "$ctl" &
    server_pid=$!

    exec 3>"$ctl"

    shutdown() {
      printf '\nproject-zomboid: saving (can take a minute)\n'
      printf 'save\n' >&3 || true
      sleep 10
      printf 'quit\n' >&3 || true
      exec 3>&- || true
      wait "$server_pid" 2>/dev/null || true
    }
    trap 'shutdown; exit 0' INT TERM

    # Forward terminal input. End-of-input (Ctrl-D, or the terminal closing) ends
    # the loop and triggers the same clean shutdown, so the JVM is never orphaned.
    while IFS= read -r line; do
      printf '%s\n' "$line" >&3 || break
    done

    shutdown
    PZ_EOF

    chmod +x "$out/bin/pz-dedicated-server"
    runHook postInstall
  '';

  meta = {
    description = "Run a Project Zomboid dedicated server without a NixOS host";
    longDescription = ''
      Downloads and validates the Project Zomboid dedicated server with
      steamcmd, writes the server configuration from the modpack catalogue, and
      runs it with your terminal as the console — Ctrl-C saves and quits cleanly
      rather than killing the JVM mid-save.

      Shares its install, configuration and mod handling with the
      `services.project-zomboid-servers` NixOS module through lib/prepare.nix, so
      a server behaves the same whichever way it is started.
    '';
    homepage = "https://projectzomboid.com";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "pz-dedicated-server";
  };
}
