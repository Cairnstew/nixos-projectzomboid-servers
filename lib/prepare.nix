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
#   mkPrepScript  merge the base into the server's .ini, resolve maps, write
#                 SandboxVars + spawn lua, link Workshop mods
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
#
# THE ONE EXCEPTION IS `Map=`
# ---------------------------
# `Map=` is the only config key that cannot be rendered at eval time: a map only
# exists if some installed mod ships it under `media/maps/`, and which mods are
# installed is not known until steamcmd has run. So when `map` is unset,
# scripts/pz_maps.py derives the list at start from what is actually on disk —
# deterministically, and with collisions reported rather than silently resolved.
# See `pz-maps` in the README.
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
  #
  # Secrets are NEVER rendered here. This is a `pkgs.writeText` store path, so it
  # is mode 444 and world-readable; they travel separately as `--secret-file
  # Key=path` and are read by merge_ini.py at start.
  #
  # `Map=` is likewise absent unless the configuration pins it — see the header.
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
          legacyBuild41 = server.compatibility.build41;
        }
      )
      + "\n"
    );

  # ── The `<name>_SandboxVars.lua`, rendered by Nix ──────────────────────────
  # Shared by the dedicated-server prep and the client-host prep: both OWN this
  # file outright (PZ regenerates it from whatever is on disk), so the rendering
  # must not diverge between the two ways of hosting a world.
  mkSandboxFile =
    {
      server,
      name ? "${server.serverName}_SandboxVars.lua",
    }:
    pkgs.writeText name (pz.renderSandbox { settings = server.sandbox; });

  # ── Per-server start-prep ──────────────────────────────────────────────────
  # `server` is a `pz.resolveServer` result.
  mkPrepScript =
    {
      name ? "project-zomboid-prepare",
      server,
      iniBase,
      mergeIni ? ../scripts/merge_ini.py,
      mapsPy ? ../scripts/pz_maps.py,
      # Steam's *join* app id; Workshop content lives under it.
      steamAppId ? "108600",
    }:
    let
      sandboxFile = mkSandboxFile { inherit server; };

      # Spawn lua. PZ writes these itself when they are absent, so we own them
      # outright — but only when there is something to say: rendering an empty
      # SpawnRegions() would be an empty override of the game's own.
      hasSpawnPoints = server.spawn.points != [ ];
      hasSpawnRegions = server.spawn.regions != [ ];

      spawnPointsText = pz.renderSpawnPoints server.spawn.points;
      spawnRegionsText = pz.renderSpawnRegions server.spawn.regions;

      # Arguments for the map resolver. The POLICY (strict, dedupe, priority) is a Nix
      # value by default, but each part can be overridden from the environment so
      # the standalone runner can change it at runtime without a second
      # implementation of the resolution. Only the RESULT is genuinely runtime,
      # because it depends on what is installed.
      mapOrder = server.mapOrder;
      nixPriorityArgs = concatMapStringsSep " " (
        id: "--priority ${lib.escapeShellArg id}"
      ) mapOrder.priority;
      baseMapLiteral = lib.escapeShellArg server.baseMap;
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
        server_conf="$server_home/Zomboid/Server"
        mkdir -p "$server_conf" \
                 "$server_home/Zomboid/Workshop/content/${steamAppId}" \
                 "$server_home/Zomboid/Logs" \
                 "$server_home/Zomboid/Saves/Multiplayer/$pz_name"

        # ── Resolve `Map=` from the installed mods ────────────────────────────
        # The only config value derived at runtime. `pz_maps.py` orders the maps
        # by a total sort key, so this is reproducible; the base map is always
        # last, and any duplicate map name is reported on stderr.
        map_override=""
        ${optionalString server.autoMaps ''
          # Nix decided this block exists (map is null); the environment only
          # decides whether the CALLER has already supplied a Map=.
          if [ "''${PZ_MAP_PINNED:-0}" != "1" ]; then
            base_map="''${PZ_BASE_MAP:-${baseMapLiteral}}"
            map_strict="''${PZ_MAP_STRICT:-${if mapOrder.strict then "1" else "0"}}"
            map_dedupe="''${PZ_MAP_DEDUPE:-${if mapOrder.dedupe then "1" else "0"}}"

            priority_args=()
            # PZ_MAP_PRIORITY is colon-separated (an env var cannot hold an array)
            # and falls back to the Nix-side list when unset or empty.
            raw_priority="''${PZ_MAP_PRIORITY-}"
            if [ -z "$raw_priority" ]; then
              # shellcheck disable=SC2086
              priority_args=(${nixPriorityArgs})
            else
              while IFS= read -r id; do
                [ -n "$id" ] && priority_args+=(--priority "$id")
              done <<< "''${raw_priority//:/$'\n'}"
            fi

            strict_flag=()
            [ "$map_strict" = "1" ] && strict_flag=(--strict)
            dedupe_flag=()
            [ "$map_dedupe" = "1" ] && dedupe_flag=(--dedupe)

            map_value="$(python3 ${mapsPy} \
              --workshop-root "$PZ_SERVER_DIR/steamapps/workshop/content/${steamAppId}" \
              --local-mods "$server_home/Zomboid/mods" \
              --base-map "$base_map" \
              "''${priority_args[@]}" "''${strict_flag[@]}" "''${dedupe_flag[@]}"
            )" || {
              echo "project-zomboid: map resolution failed (see above)" >&2
              exit 1
            }
            if [ -z "$map_value" ]; then
              echo "project-zomboid: no maps resolved; leaving Map= unset" >&2
            else
              map_override="Map=$map_value"
            fi
          fi
        ''}
        ${optionalString (server.autoMaps == false) ''
          map_override="Map=${server.pinnedMap}"
        ''}

        # Merged, NOT overwritten: Seed / ResetID / LastModified / ServerPlayerID
        # live in this same file, and rewriting it would reset the world on every
        # start. merge_ini.py touches only the keys it is given.
        #
        # Precedence inside merge_ini.py: existing file < --from-file < argv <
        # --secret-file. "$@" is the caller-supplied override layer, so the
        # standalone runner can change a port at runtime without re-rendering the
        # Nix-side base config. With no arguments it expands to nothing.
        #
        # NO shell comments inside the command itself: a `#` line within a `\`
        # continuation is a SHELL comment and swallows the rest of the command.
        #
        # The map_override expansion below uses the colon form with the quotes round
        # the INNER value only (doll-brace v, colon-plus, dollar-quote m,
        # dollar-quote close-brace).
        #
        # Two traps, both of which shipped a bug at some point:
        #   * the bare `+` form expands the alternate whenever v is SET, and an
        #     empty `v=""` is set, so it passes a spurious argument;
        #   * quoting the WHOLE expansion is worse: a quoted expansion is a
        #     single word that never disappears, so it passes one EMPTY argument
        #     even when the colon form correctly chooses to expand to nothing.
        #     That one reached merge_ini.py as a bare "" and aborted the start.
        # Quoting only the inner value gives zero arguments when empty and
        # exactly one (spaces and semicolons intact) when set.
        python3 ${mergeIni} \
          "$server_conf/$pz_name.ini" \
          --from-file ${iniBase} \
          ${optionalString server.softReset "--soft-reset"} \
          ${pz.secretFileArgs server} \
          ''${map_override:+"''$map_override"} \
          ${optionalString (builtins.length (pz.iniUpdates server) > 0) ''
            "$@" \
          ''}

        # SandboxVars is regenerated by PZ itself, so we own it outright.
        #
        # `install -m 0644`, NOT `cp`: a store file is mode 444, and `cp` gives a
        # NEW file the source's permissions, so the destination would be created
        # read-only — and the next start would then fail with "cp: cannot create
        # regular file: Permission denied". In production PZ happens to rewrite
        # the file in between and masks this, which is exactly why it survived;
        # `install` unlinks first, so it is correct regardless of what the
        # destination's current mode is.
        install -m 0644 ${sandboxFile} "$server_conf/''${pz_name}_SandboxVars.lua"

        # Spawn lua, same reasoning — owned, but only written when non-empty.
        # When emptied the file is REMOVED rather than left stale, and PZ
        # regenerates its own; otherwise removing the option would silently have
        # no effect on an already-running server.
        ${optionalString hasSpawnPoints ''
          install -m 0644 ${pkgs.writeText "${server.serverName}_spawnpoints.lua" spawnPointsText} \
            "$server_conf/''${pz_name}_spawnpoints.lua"
        ''}
        ${optionalString (hasSpawnPoints == false) ''
          rm -f "$server_conf/''${pz_name}_spawnpoints.lua"
        ''}
        ${optionalString hasSpawnRegions ''
          install -m 0644 ${pkgs.writeText "${server.serverName}_spawnregions.lua" spawnRegionsText} \
            "$server_conf/''${pz_name}_spawnregions.lua"
        ''}
        ${optionalString (hasSpawnRegions == false) ''
          rm -f "$server_conf/''${pz_name}_spawnregions.lua"
        ''}

        # Link each Workshop item from the shared install into this server's home.
        # Redone every start so a newly added mod appears with no manual step and a
        # removed one is un-linked. Symlinks only, so the shared download is safe.
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

  # ── Client-host prep ───────────────────────────────────────────────────────
  # Sibling of `mkPrepScript` for the OTHER way a Project Zomboid world runs:
  # the in-game Host button, which runs the server inside the CLIENT's own
  # process. A pack described once must drive both hosts, so the `.ini` merge and
  # the SandboxVars rendering above are shared verbatim — otherwise the mod list
  # would be written down twice and the two would drift.
  #
  # What differs is only where the files land, and that there is no install or
  # update step: Steam owns the client's game and updates it on its own schedule.
  #
  # Runtime inputs come from the environment, because the client's Zomboid home
  # and Steam library are user-level paths this module cannot know:
  #
  #   PZ_CLIENT_ZOMBOID    the client's Zomboid home, e.g. ~/Zomboid   (required)
  #   PZ_SERVER_DIR        the shared steamcmd install (Workshop source)
  #   PZ_CLIENT_WORKSHOP   the client library's
  #                        `steamapps/workshop/content/<steamAppId>` directory
  #
  # When BOTH of the last two are set, every Workshop item this server needs is
  # symlinked from the shared install into the client library, so ONE download
  # serves both hosts. Leaving PZ_CLIENT_WORKSHOP unset skips that and expects the
  # client to have subscribed on Steam — which is the only thing a hosted world
  # cannot do for joining players (`WorkshopItems=` makes them download it).
  #
  # `install -m 0644`, never `cp`, for the same reason as the dedicated path: the
  # source is a store file at mode 444 and `cp` would create a read-only
  # destination that PZ could not then rewrite.
  mkClientHostScript =
    {
      name ? "project-zomboid-client-host",
      server,
      iniBase,
      # The client-side server name — `Zomboid/Server/<clientName>.ini`. NOT
      # `server.serverName`: on a client host the dedicated server's name is
      # usually absent or irrelevant, and the game names the file after what its
      # own Host screen is called (`servertest` by default).
      clientName ? server.serverName,
      mergeIni ? ../scripts/merge_ini.py,
      steamAppId ? "108600",
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.python3
      ];
      text = ''
        require_env() {
          if [ -z "''${!1-}" ]; then
            echo "project-zomboid: $1 must be set" >&2
            exit 1
          fi
        }
        require_env PZ_CLIENT_ZOMBOID

        pz_name="${clientName}"
        server_conf="$PZ_CLIENT_ZOMBOID/Server"
        mkdir -p "$server_conf"

        # MERGED, not overwritten. Once the client has hosted this world the very
        # same file carries Seed / ServerPlayerID / LastModified, so rewriting it
        # wholesale would reset the world — the identical trap the dedicated
        # server's merge exists for, hence the same merge_ini.py.
        python3 ${mergeIni} \
          "$server_conf/$pz_name.ini" \
          --from-file ${iniBase} \
          ${pz.secretFileArgs server} \
          ${optionalString (builtins.length (pz.iniUpdates server) > 0) ''
            "$@" \
          ''}

        install -m 0644 ${mkSandboxFile { inherit server; }} \
          "$server_conf/''${pz_name}_SandboxVars.lua"

        # One download, two hosts. Skipped unless the caller names a client
        # Workshop directory, so a Steam-subscribed client is left alone.
        if [ -n "''${PZ_CLIENT_WORKSHOP-}" ]; then
          require_env PZ_SERVER_DIR
          mkdir -p "$PZ_CLIENT_WORKSHOP"
          ${concatStringsSep "\n" (
            map (id: ''
              src="$PZ_SERVER_DIR/steamapps/workshop/content/${steamAppId}/${id}"
              dst="$PZ_CLIENT_WORKSHOP/${id}"
              if [ -d "$src" ]; then
                ln -sfn "$src" "$dst"
              elif [ -L "$dst" ]; then
                rm -f "$dst"
              fi
            '') server.workshopItems
          )}
        fi

        echo "project-zomboid: prepared client host $pz_name in $server_conf"
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
      # null = stable branch. `legacy41` and friends are Steam beta branches; the
      # flag must sit BETWEEN app_update and validate, which is why it is
      # interpolated here rather than appended by the caller.
      betaBranch ? null,
    }:
    let
      # Unique at EVAL time (static data), shell-escaped for the array literal.
      items = concatMapStringsSep " " lib.escapeShellArg (lib.unique workshopItems);
      betaFlag = optionalString (betaBranch != null) "-beta ${betaBranch} ";
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

        echo "project-zomboid: validating dedicated server (app ${serverAppId}${
          optionalString (betaBranch != null) ", beta ${betaBranch}"
        })"
        steamcmd +app_update ${serverAppId} ${betaFlag}validate

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
