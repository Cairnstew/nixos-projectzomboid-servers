# lib/prepare.nix
#
# The two pieces of logic needed to get a Project Zomboid dedicated server from
# "nothing on disk" to "running", factored out of modules/services.nix so the
# NixOS module and the standalone runner (`nix run .#pz-dedicated-server`) share
# ONE implementation.
#
# That sharing is the point. The `.ini` merge especially: it must preserve
# Project Zomboid's world-identity keys (Seed, ResetID, ServerPlayerID), and two
# copies of that logic would drift — and the wrong one would reset worlds.
#
#   mkIniBase     the Nix-rendered base .ini, as a store file
#   mkPrepScript  merge the base into the server's .ini, write SandboxVars,
#                 link Workshop mods
#   mkInstallScript  steamcmd app_update + Workshop downloads
#
# THE RUNTIME INPUTS COME FROM THE ENVIRONMENT, not from Nix interpolation: the
# data directory and the server name are runtime arguments for the standalone
# runner, so a script with `/srv/whatever` or `pz` baked in could not be shared
# with it — and the NixOS module gets the same scripts for free by setting the
# environment in its unit. Callers must provide:
#
#   PZ_DATA_DIR      the base data directory
#   PZ_SERVER_DIR    the steamcmd install
#   PZ_SERVER_NAME   the Project Zomboid server name
#
# Everything else — which keys, which mods, which sandbox vars — IS Nix-side,
# because that is catalogue data and must stay declarative.
{
  lib,
  pkgs,
  pz,
}:

let
  inherit (lib) concatStringsSep concatMapStringsSep optionalString;
in
rec {
  # ── The base `.ini`, rendered by Nix ────────────────────────────────────────
  # A store file of `Key=value` lines: the pack's defaults, the module-owned keys
  # and the server's inline settings, already merged and ordered by
  # `pz.renderIniLines`. Kept separate from the merge so the runner can layer
  # runtime overrides (a different --port) on top without re-rendering.
  mkIniBase =
    {
      server,
      name ? "pz-server.ini",
    }:
    pkgs.writeText name (
      concatStringsSep "\n" (
        pz.renderIniLines {
          inherit (server)
            settings
            mods
            workshopItems
            whitelist
            admins
            ;
        }
      )
      + (optionalString (server.passwordFile != null) "Password=@password-file@")
      + "\n"
    );

  # ── Per-server start-prep ──────────────────────────────────────────────────
  # `server` is a `pz.resolveServer` result.
  mkPrepScript =
    {
      name ? "project-zomboid-prepare",
      server,
      iniBase,
      mergeIni ? ../scripts/merge_ini.py,
      # Steam's *join* app id; Workshop content lives under it.
      steamAppId ? "108600",
    }:
    let
      # Fully declarative and secret-free, so it can live in the store. Keeping it
      # out of the shell script also stops a multi-line value from de-indenting the
      # surrounding Nix string and breaking a heredoc terminator.
      sandboxFile = pkgs.writeText "${server.serverName}_SandboxVars.lua" (
        pz.renderSandbox { settings = server.sandbox; }
      );
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.python3
      ];
      text = ''
        # Explicit guards rather than ${"VAR:?message"}: a message containing
        # parentheses makes bash's parser lose track of the closing brace, which
        # surfaces as a baffling "unexpected EOF while looking for matching `}'".
        require_env() {
          if [ -z "''${!1-}" ]; then
            echo "project-zomboid: $1 must be set" >&2
            exit 1
          fi
        }
        require_env PZ_DATA_DIR
        require_env PZ_SERVER_DIR
        require_env PZ_SERVER_NAME

        # Runtime, not `server.serverName`: the standalone runner's server name is
        # a CLI argument, so it cannot be baked in here.
        pz_name="$PZ_SERVER_NAME"
        server_home="$PZ_DATA_DIR/$pz_name"
        mkdir -p "$server_home/Zomboid/Server" \
                 "$server_home/Zomboid/Workshop/content/${steamAppId}" \
                 "$server_home/Zomboid/Logs" \
                 "$server_home/Zomboid/Saves/Multiplayer/$pz_name"

        # Merged, NOT overwritten: Seed / ResetID / LastModified / ServerPlayerID
        # live in this same file, and rewriting it would reset the world on every
        # start. merge_ini.py touches only the keys it is given.
        #
        # Precedence inside merge_ini.py: existing file < --from-file < argv <
        # --password-file. "$@" is the caller-supplied override layer, so the
        # standalone runner can change a port at runtime without re-rendering the
        # Nix-side base config. With no arguments it expands to nothing.
        python3 ${mergeIni} \
          "$server_home/Zomboid/Server/$pz_name.ini" \
          --from-file ${iniBase} \
          ${
            concatStringsSep " \\\n          " (
              lib.optional (server.passwordFile != null) "--password-file ${server.passwordFile}"
            )
          }"$@"

        # SandboxVars is regenerated by PZ itself, so we own it outright.
        cp ${sandboxFile} "$server_home/Zomboid/Server/''${pz_name}_SandboxVars.lua"

        # Link each Workshop item from the shared install into this server's home.
        # Redone every start so a newly added mod appears with no manual step and a
        # removed one is unlinked. Symlinks only, so the shared download is safe.
        ${concatStringsSep "\n" (
          map (id: ''
            src="$PZ_SERVER_DIR/steamapps/workshop/content/${steamAppId}/${id}"
            dst="$server_home/Zomboid/Workshop/content/${steamAppId}/${id}"
            if [ -d "$src" ]; then
              mkdir -p "$(dirname "$dst")"
              ln -sfn "$src" "$dst"
            elif [ -L "$dst" ]; then
              rm -f "$dst"
            fi
          '') server.workshopItems
        )}

        echo "project-zomboid: prepared $pz_name in $server_home"
      '';
    };

  # ── Install / update the shared server ──────────────────────────────────────
  # One install serves every server: PZ's binaries are identical, only the
  # Zomboid home differs.
  #
  # Workshop ids are de-duplicated at EVAL time by the caller, because they are
  # static data — two servers sharing a pack must not trigger two downloads.
  mkInstallScript =
    {
      name ? "project-zomboid-install",
      steamcmd,
      serverAppId ? "380870",
      steamAppId ? "108600",
      workshopItems ? [ ],
    }:
    let
      # Unique at EVAL time (static data), shell-escaped for the array literal.
      items = concatMapStringsSep " " lib.escapeShellArg (lib.unique workshopItems);
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        steamcmd
        pkgs.coreutils
      ];
      text = ''
        require_env() {
          if [ -z "''${!1-}" ]; then
            echo "project-zomboid: $1 must be set" >&2
            exit 1
          fi
        }
        require_env PZ_DATA_DIR
        require_env PZ_SERVER_DIR

        mkdir -p "$PZ_DATA_DIR" "$PZ_SERVER_DIR"

        # steamcmd resolves relative paths against HOME unless forced; be explicit
        # so an ambient HOME cannot land the install somewhere unexpected.
        export HOME="$PZ_DATA_DIR"

        steamcmd() {
          ${lib.getExe steamcmd} \
            +force_install_dir "$PZ_SERVER_DIR" \
            +login anonymous "$@" +quit
        }

        echo "project-zomboid: validating dedicated server (app ${serverAppId})"
        steamcmd +app_update ${serverAppId} validate

        # The *join* app id goes in steam_appid.txt, not the dedicated-server one.
        # Exactly one line: a stale multi-id file aborts Build 42 with
        # "Assertion Failed: Illegal termination of worker thread".
        printf '%s\n' '${steamAppId}' > "$PZ_SERVER_DIR/steam_appid.txt"

        workshop_root="$PZ_SERVER_DIR/steamapps/workshop/content/${steamAppId}"

        items=(${items})
        if [ "''${#items[@]}" -eq 0 ]; then
          echo "project-zomboid: no Workshop mods requested"
        fi

        for id in "''${items[@]}"; do
          if [ -d "$workshop_root/$id" ]; then
            echo "project-zomboid: Workshop item $id already present"
            continue
          fi
          echo "project-zomboid: downloading Workshop item $id"
          steamcmd +workshop_download_item ${steamAppId} "$id"
        done

        echo "project-zomboid: install ready in $PZ_SERVER_DIR"
      '';
    };
}
