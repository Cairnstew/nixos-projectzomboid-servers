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

  # Referenced directly rather than via PATH: this script is written by hand in
  # installPhase, so it gets none of writeShellApplication's environment.
  steamAppId = project-zomboid-server.steamAppId;
  mapsPy = ../../scripts/pz_maps.py;

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
    jvm_opts="${resolvedServer.jvmOpts}"
    do_install=1
    print_only=0
    list_maps=0
    # Map policy. These override the Nix-side defaults via the environment,
    # because lib/prepare.nix reads map policy from env for exactly this reason —
    # one implementation, two callers. `--map` skips detection entirely.
    map_override=""
    base_map="${resolvedServer.baseMap}"
    strict_maps=0
    dedupe_maps=0
    declare -a map_priority=()
    declare -a overrides=()
    declare -a extra_args=()
    # `Key=path` pairs, turned into `--secret-file Key=path` for the prep script.
    declare -a secrets=()
    admin_user=""
    admin_pass_file=""
    soft_reset=0
    # Runtime auth + prune: this script has no Nix server definition to read a
    # default from, so lib/prepare.nix reads both from the environment.
    steam_login=""
    prune=0
    lenient=0

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
      --map NAME           pin Map= (default: derive from the installed mods)
      --base-map NAME      the vanilla map, ordered last (default: ${resolvedServer.baseMap})
      --map-priority ID    mod id that wins a duplicate-map clash; repeatable
      --strict-maps        fail if two mods ship the same map name
      --dedupe-maps        rename duplicate map folders out of the way
      --jvm-opts "FLAGS"   (default: ${resolvedServer.jvmOpts})
      --set KEY=VALUE      extra .ini key, repeatable; wins over the modpack
      --secret KEY=PATH    read an .ini key's value from a file (e.g. Password)
      --extra-arg ARG      argument for the server command line; repeatable
      --admin-user NAME    create/update the Build 42 admin account
      --admin-pass-file P  file holding its password (required with --admin-user)
      --soft-reset         discard world identity, generating a fresh world
      --login NAME         Steam account for gated Workshop items (default: anonymous)
      --prune              remove mods no longer declared (shared cache + link farms)
      --lenient            log-and-skip Workshop items that cannot be downloaded
                           instead of failing the install (the server boots without them)
      --no-install         skip the steamcmd validate (much faster restarts)
      --list-maps          print the derived Map= list and exit
      --print-config       write the config, print it, exit — needs no game files
      -h, --help           this message

    --list-maps is the one to reach for when a mod is not showing up on the map:
    it reports which mods ship which maps, in which order, and flags any clash.

    Spawn points and regions are Nix-side (like the modpack itself), so they are
    not runtime flags here — set them on the server definition.
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
        --map)        map_override="$2"; shift 2 ;;
        --base-map)   base_map="$2";   shift 2 ;;
        --map-priority) map_priority+=("$2"); shift 2 ;;
        --strict-maps) strict_maps=1; shift ;;
        --dedupe-maps) dedupe_maps=1; shift ;;
        --jvm-opts)   jvm_opts="$2";   shift 2 ;;
        --set)        overrides+=("$2"); shift 2 ;;
        --secret)     secrets+=("$2"); shift 2 ;;
        --extra-arg)  extra_args+=("$2"); shift 2 ;;
        --admin-user) admin_user="$2"; shift 2 ;;
        --admin-pass-file) admin_pass_file="$2"; shift 2 ;;
        --soft-reset) soft_reset=1; shift ;;
        --login)      steam_login="$2"; shift 2 ;;
        --prune)      prune=1;         shift ;;
        --lenient)    lenient=1;       shift ;;
        --no-install) do_install=0;    shift ;;
        --list-maps)  list_maps=1;     shift ;;
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

    # Checked here, before the multi-gigabyte install, rather than at the point of
    # use: failing after a 20-minute download is a poor trade for a typo.
    if [ -n "$admin_user" ] && [ -z "$admin_pass_file" ]; then
      echo "pz-dedicated-server: --admin-user needs --admin-pass-file" >&2
      exit 2
    fi
    if [ -z "$admin_user" ] && [ -n "$admin_pass_file" ]; then
      echo "pz-dedicated-server: --admin-pass-file needs --admin-user" >&2
      exit 2
    fi

    : "''${server_dir:=$data_dir/server}"
    export PZ_DATA_DIR="$data_dir"
    export PZ_SERVER_DIR="$server_dir"
    # The prep script is shared with the NixOS module and reads the server name
    # from here, because it is a runtime argument rather than Nix data.
    export PZ_SERVER_NAME="$server_name"

    # Auth + prune, read by lib/prepare.nix from the environment so the shared
    # install and prep scripts honour them without a second implementation.
    # Only exported when set, so the script's own anonymous default applies.
    if [ -n "$steam_login" ]; then
      export PZ_STEAM_LOGIN="$steam_login"
    fi
    export PZ_PRUNE="$prune"
    if [ "$lenient" -eq 1 ]; then
      export PZ_FAIL_ON_MISSING=0
    fi

    # Map policy overrides, so the shared prep script can honour runtime flags
    # without a second implementation. PZ_MAP_PRIORITY is colon-separated
    # because an env var cannot hold an array.
    export PZ_BASE_MAP="$base_map"
    map_priority_argv=()
    for id in "''${map_priority[@]+"''${map_priority[@]}"}"; do
      map_priority_argv+=(--priority "$id")
    done
    export PZ_MAP_PRIORITY="$(IFS=:; echo "''${map_priority[*]-}")"
    export PZ_MAP_STRICT="$strict_maps"
    export PZ_MAP_DEDUPE="$dedupe_maps"
    # A pinned Map= means the caller supplies it, so skip detection: otherwise
    # the resolver's warnings would fire for a value that is about to be
    # overwritten anyway.
    if [ -n "$map_override" ]; then
      export PZ_MAP_PINNED=1
    else
      export PZ_MAP_PINNED=0
    fi

    printf 'project-zomboid: server    %s\n' "$server_name"
    printf 'project-zomboid: modpack   %s\n' "''${modpack:-none}"
    printf 'project-zomboid: data-dir  %s\n' "$PZ_DATA_DIR"
    printf 'project-zomboid: install   %s\n' "$PZ_SERVER_DIR"
    printf 'project-zomboid: ports     %s (udp) / %s (udp) / %s (rcon)\n' \
      "$port" "$udp_port" "$rcon_port"

    mkdir -p "$PZ_DATA_DIR"

    # ── List maps ─────────────────────────────────────────────────────────────
    # Answer "why is this mod's map not loading" without starting a server, and
    # without needing the game installed at all.
    if [ "$list_maps" -eq 1 ]; then
      if [ "$do_install" -eq 1 ]; then
        ${installScript}/bin/project-zomboid-install
      fi
      exec ${lib.getExe pkgs.python3} ${mapsPy} \
        --workshop-root "$PZ_SERVER_DIR/steamapps/workshop/content/${steamAppId}" \
        --local-mods "$PZ_DATA_DIR/$server_name/Zomboid/mods" \
        --base-map "$base_map" \
        "''${map_priority_argv[@]+''${map_priority_argv[@]}}" \
        --explain --format list
    fi

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
    #
    # --secret turns `Key=path` into `--secret-file Key=path`, so a secret never
    # lands in the Nix-rendered base ini (a world-readable store path).
    secret_args=()
    for pair in "''${secrets[@]+"''${secrets[@]}"}"; do
      secret_args+=(--secret-file "$pair")
    done

    # --soft-reset is a flag on the prepare script, not a Key=value: it makes
    # merge_ini.py DELETE keys, which an override could not express.
    reset_args=()
    if [ "$soft_reset" -eq 1 ]; then
      reset_args=(--soft-reset)
    fi

    # A pinned Map= is just another override. PZ_MAP_PINNED=1 (set above) already
    # stopped the prepare script resolving one, and an override passed as "$@"
    # wins over anything the script derives anyway.
    pin_args=()
    if [ -n "$map_override" ]; then
      pin_args=("Map=$map_override")
    fi

    ${prepScript}/bin/project-zomboid-prepare \
      "DefaultPort=$port" \
      "UDPPort=$udp_port" \
      "RCONPort=$rcon_port" \
      "MaxPlayers=$max_players" \
      "PublicName=$server_name" \
      ''${reset_args[@]+"''${reset_args[@]}"} \
      ''${secret_args[@]+"''${secret_args[@]}"} \
      ''${pin_args[@]+"''${pin_args[@]}"} \
      ''${overrides[@]+"''${overrides[@]}"}

    ini="$PZ_DATA_DIR/$server_name/Zomboid/Server/$server_name.ini"
    server_conf="$PZ_DATA_DIR/$server_name/Zomboid/Server"
    sandbox="$server_conf/''${server_name}_SandboxVars.lua"

    if [ "$print_only" -eq 1 ]; then
      printf '\n== %s ==\n' "$ini"
      cat "$ini"
      printf '\n== %s ==\n' "$sandbox"
      cat "$sandbox"
      # Spawn lua is Nix-rendered and only present when configured, so print
      # whatever actually landed rather than failing on a missing file.
      for f in "$server_conf/''${server_name}_spawnpoints.lua" \
               "$server_conf/''${server_name}_spawnregions.lua"; do
        if [ -f "$f" ]; then
          printf '\n== %s ==\n' "$f"
          cat "$f"
        fi
      done
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

    # The launcher reads the admin password from PZ_ADMIN_PASSWORD_FILE itself,
    # so only the username and the path cross this boundary — the value never
    # becomes a command-line argument of THIS shell.
    if [ -n "$admin_user" ]; then
      export PZ_ADMIN_USERNAME="$admin_user"
      export PZ_ADMIN_PASSWORD_FILE="$admin_pass_file"
      printf 'project-zomboid: admin     %s\n' "$admin_user"
    fi

    ${lib.getExe project-zomboid-server} "$server_name" \
      ''${extra_args[@]+"''${extra_args[@]}"} \
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
