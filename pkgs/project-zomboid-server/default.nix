# pkgs/project-zomboid-server/default.nix
#
# The launcher package: `pkgs.project-zomboid-server`.
#
# Reads the non-rotating ids from versions.json (app ids, default ports) and
# builds the shell wrapper that launches a steamcmd-installed PZ server.
#
# NOT here yet, on purpose: Steam depot `manifestId` + content hash. Those
# rotate on every PZ build, so they cannot be hand-committed honestly; they need
# a generated manifest from a real fetcher (`fetchSteam` from
# nix-community/steam-fetcher — note it is NOT in nixpkgs). Until that exists,
# the game binary is fetched by steamcmd into `serverDir` at activation time.
# The shape here is ready for it: swap the wrapper for a `fetchurl`-style
# derivation and `serverDir` becomes a store path.
{
  lib,
  stdenvNoCC,
  writeShellApplication,
  steam-run,
}:

let
  versions = lib.importJSON ./versions.json;

  # The game is not pinned (see versions.json), so the package version tracks the
  # dedicated-server Steam app id rather than pretending to be a PZ build number.
  version = "app-${versions.serverAppId}";

  # ── The launcher ───────────────────────────────────────────────────────────
  # Built with writeShellApplication so `set -euo pipefail`, the runtime shell
  # and a shellcheck pass come for free and are enforced at build time.
  #
  # Three things it does that a bare `start-server.sh` invocation does not:
  #
  #   1. steam_appid.txt is written with exactly one line (the *join* app id,
  #      108600 — not the dedicated-server app id). Two or more lines makes
  #      Build 42 abort with
  #      `Assertion Failed: Illegal termination of worker thread`. It is
  #      overwritten, never appended, so a stale file cannot accumulate.
  #   2. JVM heap flags are injected *ahead of* the launcher so they are not
  #      shadowed by its own hardcoded -Xms/-Xmx. The wiki is explicit that you
  #      must edit these; the script ignores anything set after it.
  #   3. It `exec`s the launcher, so the JVM inherits our PID. start-server.sh
  #      does not forward signals to ProjectZomboid64 — which is exactly why the
  #      unit stops by writing `quit` to the console FIFO with KillSignal=SIGCONT
  #      rather than by signalling the process.
  #   4. It appends the Build 42 admin login from `PZ_ADMIN_USERNAME` /
  #      `PZ_ADMIN_PASSWORD_FILE`. PZ has no ini key for the admin account, so the
  #      argument pair is the only way; the password is read from a file here so it
  #      never reaches the Nix store or the unit file.
  #
  # Bound in `let` (not in the mkDerivation attrset) so `passthru` — a *nested*
  # attrset, which Nix does NOT make self-recursive — can reach it too.
  launcher = writeShellApplication {
    name = "project-zomboid-server";
    runtimeInputs = [ steam-run ];
    text = ''
        server_name="''${1-}"
        if [ -z "$server_name" ] || [ "$server_name" = "-h" ] || [ "$server_name" = "--help" ]; then
          cat >&2 <<'USAGE'
      usage: project-zomboid-server <server-name> [extra server args...]

      Environment:
        PZ_SERVER_DIR          install dir containing start-server.sh (required)
        PZ_JVM_OPTS            JVM flags, e.g. "-Xmx8G -Xms4G" (optional)
        PZ_ADMIN_USERNAME      Build 42 admin account name (optional)
        PZ_ADMIN_PASSWORD_FILE file holding its password (required with the above)
      USAGE
        exit 2
      fi
        shift

        if [ -z "''${PZ_SERVER_DIR-}" ]; then
          echo "project-zomboid-server: PZ_SERVER_DIR is not set" >&2
          exit 1
        fi

        launcher_path="$PZ_SERVER_DIR/start-server.sh"
        if [ ! -x "$launcher_path" ]; then
          echo "project-zomboid-server: $launcher_path is missing or not executable" >&2
          echo "  install the server first: steamcmd +login anonymous +app_update ${versions.serverAppId} validate +quit" >&2
          exit 1
        fi

        # (1) Exactly one app id, one line. Not the dedicated-server app id.
        printf '%s\n' '${versions.steamAppId}' > "$PZ_SERVER_DIR/steam_appid.txt"

        cd "$PZ_SERVER_DIR"

        # (2) Split the flag list into an array rather than relying on unquoted
        #     word splitting: correct for empty PZ_JVM_OPTS, and shellcheck-clean
        #     without a suppression.
        jvm_opts=()
        if [ -n "''${PZ_JVM_OPTS-}" ]; then
          read -r -a jvm_opts <<< "''${PZ_JVM_OPTS-}"
        fi

        # (4) The Build 42 admin login. There is no ini key for this — the
        #     account is a row in Zomboid/db/<servername>.db and the only way to
        #     write it is this argument pair — so the password has to arrive on
        #     the command line. Read it here from the file rather than having it
        #     interpolated into the unit, so it never reaches the Nix store.
        #
        #     The value is unavoidably visible in `ps` for the lifetime of the
        #     server. That is a Project Zomboid limitation, not one this module
        #     can design around; see the `adminAccount` option.
        admin_args=()
        if [ -n "''${PZ_ADMIN_USERNAME-}" ]; then
          if [ -z "''${PZ_ADMIN_PASSWORD_FILE-}" ]; then
            echo "project-zomboid-server: PZ_ADMIN_USERNAME is set but PZ_ADMIN_PASSWORD_FILE is not" >&2
            exit 1
          fi
          if [ ! -r "$PZ_ADMIN_PASSWORD_FILE" ]; then
            echo "project-zomboid-server: cannot read PZ_ADMIN_PASSWORD_FILE" >&2
            exit 1
          fi
          admin_password="$(cat "$PZ_ADMIN_PASSWORD_FILE")"
          if [ -z "$admin_password" ]; then
            echo "project-zomboid-server: PZ_ADMIN_PASSWORD_FILE is empty" >&2
            exit 1
          fi
          admin_args=(-adminusername "$PZ_ADMIN_USERNAME" -adminpassword "$admin_password")
        fi

        # (3) exec so the JVM inherits this PID and receives signals directly.
        exec ${lib.getExe steam-run} "$launcher_path" "''${jvm_opts[@]}" \
          -servername "$server_name" "''${admin_args[@]}" "$@"
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "project-zomboid-server";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    ln -s ${launcher}/bin/project-zomboid-server "$out/bin/project-zomboid-server"
    runHook postInstall
  '';

  passthru = {
    inherit launcher;
    steamAppId = versions.steamAppId;
    serverAppId = versions.serverAppId;
    defaultPorts = {
      default = versions.defaultPort;
      udp = versions.defaultUdpPort;
      rcon = versions.defaultRconPort;
    };
  };

  meta = {
    description = "Launcher wrapper for a steamcmd-installed Project Zomboid dedicated server";
    longDescription = ''
      Wraps an existing Project Zomboid dedicated server install (Steam app
      ${versions.serverAppId}) so the join/steam app id and the JVM heap flags
      are right without editing the vendor's start-server.sh. The game itself is
      not included: point PZ_SERVER_DIR at a steamcmd-populated directory.
    '';
    homepage = "https://projectzomboid.com";
    license = lib.licenses.unfree;
    platforms = lib.platforms.unix;
    mainProgram = "project-zomboid-server";
  };
}
