# modules/options/types.nix
#
# The reusable option types shared by the option files in this directory.
# Not a NixOS module: it is a plain function returning an attrset of types.
{ lib }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    literalExpression
    ;
in
rec {

  # Resource / scheduler caps for a server's systemd unit. All null = no cap.
  hardware = types.submodule (
    { ... }: {
      options = {
        memoryMax = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10G";
          description = "systemd MemoryMax — hard cgroup cap; the unit is OOM-killed above it. null = unlimited.";
        };
        memoryHigh = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "8G";
          description = "systemd MemoryHigh — soft throttle target. null = unlimited.";
        };
        memorySwapMax = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "2G";
          description = "systemd MemorySwapMax. null = unlimited.";
        };
        cpuQuota = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "200%";
          description = "systemd CPUQuota — percentage of one core. null = unlimited.";
        };
        nice = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "systemd Nice level. null = leave default.";
        };
        ioWeight = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "systemd IOWeight (1-10000). null = leave default.";
        };
      };
    }
  );

  # How a server's console is reached. PZ reads server commands from stdin, so
  # "the console" is fundamentally an fd 0. These backends differ in how that fd
  # is wired; exactly one is active (asserted).
  #
  # Modelled on nix-minecraft's identically-named submodule so the two modules
  # read the same way.
  managementSystem = types.submodule (
    { ... }: {
      options = {
        systemd-socket = {
          enable = mkEnableOption "the console via a systemd .socket unit with ListenFIFO (recommended)";
          # No path option: the FIFO is derived from the unit name and managed by
          # systemd, so there is nothing for the user to get wrong.
        };
        tmux = {
          enable = mkEnableOption "the console via a detached tmux session (attach with `tmux -S <sock> attach`)";
          socketPath = mkOption {
            type = types.functionTo types.path;
            default = name: "/run/project-zomboid-servers/${name}.sock";
            defaultText = literalExpression ''name: "/run/project-zomboid-servers/<name>.sock"'';
            description = "tmux control socket path. Receives `name` (the server's attribute name).";
          };
        };
      };
    }
  );

  # ── Reusable submodules ─────────────────────────────────────────────────────

  # A Steam Workshop item. Just the numeric id; the title is cosmetic and only
  # exists so a human reading the catalogue knows what they are looking at.
  workshopMod = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        example = "2847184718";
        description = ''
          Steam Workshop item id (numeric string). Downloaded into
          <literal>steamapps/workshop/content/108600/&lt;id&gt;</literal> of the
          shared install and symlinked into each server's
          <literal>Zomboid/Workshop/content/108600/</literal>.
        '';
      };
      title = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Human-readable mod title, for humans reading the pack.";
      };
    };
  };

  # One `SpawnPoints()` entry. `pos` is world coordinates, NOT a tile reference
  # and NOT an enum.
  spawnPoint = types.submodule {
    options = {
      pos = mkOption {
        type = types.listOf types.int;
        default = [
          0
          0
          0
        ];
        example = [
          12067
          6801
          0
        ];
        description = ''
          World <literal>[ x y z ]</literal> to add as a spawn point.

          Note this is a coordinate triple. PZ's own <literal>SpawnPoint=</literal>
          ini key is <emphasis>also</emphasis> a coordinate triple
          (<literal>SpawnPoint=0,0,0</literal> is the world origin) — it is not a
          preset or an index, and no small integer has a special meaning.
        '';
      };
      profession = mkOption {
        type = types.str;
        default = "unemployed";
        example = "engineer";
        description = "Profession this point spawns into. Points are grouped by this key.";
      };
    };
  };

  spawnRegion = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        example = "Mod Spawn";
        description = "Region name as PZ shows it.";
      };
      file = mkOption {
        type = types.str;
        example = "media/maps/ModName/spawnpoints.lua";
        description = ''
          Path to the region's <literal>spawnpoints.lua</literal>, relative to the
          install directory — the same form PZ's own generated file uses.
        '';
      };
    };
  };

  # Deterministic map resolution. See `map` and scripts/pz_maps.py.
  mapOrder = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Derive <literal>Map=</literal> from the maps the installed mods actually
          ship. On by default, and forced off when <option>map</option> is set to
          an explicit value (which then wins outright).
        '';
      };
      priority = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "2840889213"
        ];
        description = ''
          Mod ids that win duplicate-map collisions and order first, in the order
          listed. Ids not listed sort after all of these.

          This is the knob that makes map ordering <emphasis>deterministic</emphasis>
          rather than dependent on download order: two mods shipping the same map
          name otherwise resolve by whichever mod the loader reaches first.
        '';
      };
      strict = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Refuse to start when any two mods ship the same map name, instead of
          picking a winner and reporting it. Use in CI, or once you have confirmed
          a pack has no collisions.
        '';
      };
      dedupe = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Rename duplicate map folders out of the way
          (<literal>*.pz-duplicate</literal>) so only the winner loads.

          Off by default because it WRITES to the shared Steam install, which every
          server on that install reads. Renaming rather than deleting keeps it
          recoverable — move the folder back to undo.
        '';
      };
    };
  };

  # Secrets, as Key -> path. Values are read at start and never stored in Nix.
  secretFiles = types.attrsOf (types.nullOr types.path);

  # The Build 42 admin account, which has no ini key of its own.
  adminAccount = types.submodule {
    options = {
      username = mkOption {
        type = types.str;
        example = "seanc";
        description = ''
          Steam account name to create or update as a server admin.

          Build 42 has no ini key for this: the admin account is a row in
          <literal>Zomboid/db/&lt;servername&gt;.db</literal>, and the only
          supported way to write it is the <literal>-adminusername</literal> /
          <literal>-adminpassword</literal> command-line pair. This option passes
          them.

          <emphasis>Known limitation:</emphasis> a process argument is visible in
          <literal>ps</literal> for the lifetime of the server. PZ offers no
          alternative, and every other deployment has the same exposure — but the
          password is at least read from a file rather than baked into the unit, so
          it never reaches <literal>systemctl cat</literal> or the Nix store.
        '';
      };
      passwordFile = mkOption {
        type = types.path;
        description = ''
          File holding the admin password (e.g. an agenix secret). Read at start.
          Required — there is deliberately no way to give the password inline.
        '';
      };
    };
  };

  # A `.ini` / SandboxVars value. Kept open (oneOf) so any PZ setting can be set
  # without this module enumerating PZ's ~200 keys.
  iniSetting = types.oneOf [
    types.bool
    types.int
    types.float
    types.str
  ];
  settings = types.attrsOf iniSetting;

  # Comma-separated username list (whitelist / admins). Build 41 only — see
  # `compatibility.build41`.
  nameList = types.listOf types.str;
}
