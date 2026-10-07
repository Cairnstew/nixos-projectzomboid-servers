# modules/options.nix
#
# Options for `services.project-zomboid-servers`.
#
# Namespace mirrors nix-minecraft's `services.minecraft-servers` (plural,
# because it manages a *set* of servers), since this project is the PZ
# equivalent of that module.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    literalExpression
    ;

  # ── Shared submodules ───────────────────────────────────────────────────────

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
        example = "2625441155";
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
          "2705410157"
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
in
{
  options.services.project-zomboid-servers = {
    enable = mkEnableOption "declarative Project Zomboid dedicated servers";

    # ── Packages ─────────────────────────────────────────────────────────────

    package = mkOption {
      type = types.nullOr types.package;
      # Left null on purpose. The flake's `nixosModules` wrapper fills this in
      # with `mkDefault`, because a flake input's module scope has no way to
      # reference `self`. An explicit definition beats the `default` keyword at
      # the same priority, so this yields to the wrapper while still letting a
      # consumer override it. Defaulting it to `pkgs.project-zomboid-server`
      # instead would force every consumer to add this flake's overlay.
      default = null;
      description = ''
        The launcher wrapper. It does not contain the game — it wraps a
        steamcmd-populated install (see <option>serverDir</option>) and fixes the
        steam app id and JVM heap flags. Set by the flake to
        <literal>self.packages.\$system.project-zomboid-server</literal>; override
        to pin, patch or wrap it further.

        Must not be null; the module asserts it is set.
      '';
    };

    runDir = mkOption {
      type = types.path;
      default = "/run/project-zomboid-servers";
      example = "/run/project-zomboid";
      description = ''
        Where the per-server console FIFOs live. Created by
        <literal>systemd-tmpfiles</literal> and removed with the sockets, so
        nothing here persists a reboot.
      '';
    };

    steamcmd = mkOption {
      type = types.package;
      default = pkgs.steamcmd;
      defaultText = literalExpression "pkgs.steamcmd";
      description = "Used to install and update the dedicated server (Steam app 380870) and download Workshop mods.";
    };

    steamRun = mkOption {
      type = types.package;
      default = pkgs.steam-run;
      defaultText = literalExpression "pkgs.steam-run";
      description = ''
        FHS wrapper supplying the Steam runtime the server binary expects. PZ is
        a Steamworks title; without this it will not start.
      '';
    };

    # ── Paths ────────────────────────────────────────────────────────────────

    user = mkOption {
      type = types.str;
      default = "project-zomboid";
      description = "System user owning the shared install and running every server.";
    };

    group = mkOption {
      type = types.str;
      default = "project-zomboid";
      description = "System group matching <option>user</option>.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/project-zomboid";
      example = "/mnt/data/project-zomboid";
      description = ''
        Base directory. The shared server install lives in
        <literal>serverDir</literal> and each server's <literal>Zomboid</literal>
        home (config + saves) lives in <literal>''${dataDir}/&lt;name&gt;</literal>.
        Saves are the thing that grows without bound — point this at a large
        disk.
      '';
    };

    serverDir = mkOption {
      type = types.path;
      default = "${config.services.project-zomboid-servers.dataDir}/server";
      defaultText = literalExpression ''"''${services.project-zomboid-servers.dataDir}/server"'';
      description = ''
        The shared SteamCMD install (app 380870). One install serves every
        server: PZ's binaries are identical, only the <literal>Zomboid</literal>
        home differs.
      '';
    };

    # ── Install / update ─────────────────────────────────────────────────────

    updateOnStart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run a steamcmd validate of the shared install before each server starts.
        Every server unit <literal>Requires</literal>s the install unit, so the
        first boot fetches the game and later boots are a fast no-op validate.
        Set false if you update some other way — the servers will then fail to
        start until the install exists.
      '';
    };

    updateSchedule = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "daily";
      description = ''
        Also validate on a systemd timer with this calendar spec, restarting
        running servers afterwards so they pick up new binaries and Workshop
        mods. null = only <option>updateOnStart</option> (the default), which
        means updates land on the next restart.
      '';
    };

    restartAfterUpdate = mkOption {
      type = types.bool;
      default = true;
      description = ''
        After a timer-driven update, `try-restart` every running server so new
        binaries and mods take effect without a manual restart. Uses
        `try-restart`, so a stopped server stays stopped.
      '';
    };

    # ── Modpacks ─────────────────────────────────────────────────────────────

    modpacks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              default = "";
              description = "Human-readable description of the pack.";
            };
            workshopMods = mkOption {
              type = types.listOf workshopMod;
              default = [ ];
              description = ''
                Steam Workshop mods the pack installs. Order is preserved and
                becomes the <literal>WorkshopItems=</literal> list.
              '';
            };
            mods = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                Local mod *folder* names for the <literal>Mods=</literal> list.
                These are the <literal>id=</literal> values from each mod's
                <literal>mod.info</literal>, NOT Workshop ids — and they are
                comma-separated where WorkshopItems is semicolon-separated.
              '';
            };
            defaultSettings = mkOption {
              type = settings;
              default = { };
              description = ''
                <literal>.ini</literal> settings any server using this pack
                inherits. A server's own <option>my.services
                .project-zomboid-servers.servers.*.settings</option> wins.
              '';
            };
            defaultSandbox = mkOption {
              type = settings;
              default = { };
              description = ''
                SandboxVars any server using this pack inherits. A server's own
                <option>sandbox</option> wins.
              '';
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        {
          inherit (inputs.project-zomboid-servers.modpacks) vanilla-plus;
        }
      '';
      description = ''
        Named modpacks. This module does not ship any — the catalogue lives in
        the flake itself (<literal>inputs.project-zomboid-servers.modpacks</literal>)
        so it can be shared and versioned independently of your configuration.
        Map it in with the <option>modpacks</option> example above.
      '';
    };

    # ── Servers ──────────────────────────────────────────────────────────────

    servers = mkOption {
      type = types.attrsOf (
        types.submodule (
          { ... }: {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Run and manage this server. false = no unit is generated; data is
                  left untouched, so this is safe to toggle.
                '';
              };

              name = mkOption {
                type = types.str;
                default = "";
                description = ''
                  Project Zomboid server name — determines
                  <literal>&lt;name&gt;.ini</literal>,
                  <literal>&lt;name&gt;_SandboxVars.lua</literal> and the save
                  folder. Defaults to the attribute name here.
                '';
              };

              description = mkOption {
                type = types.str;
                default = "";
                description = "Human-readable description for the unit. Falls back to the modpack's.";
              };

              # ── Mods ────────────────────────────────────────────────────────
              modpack = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "vanilla-plus";
                description = ''
                  Which entry of <option>modpacks</option> to apply. Inline
                  <option>workshopMods</option>/<option>mods</option> are
                  *appended* to the pack's, not substituted for them.
                '';
              };

              workshopMods = mkOption {
                type = types.listOf workshopMod;
                default = [ ];
                description = "Extra Workshop mods for this server, on top of its pack's.";
              };

              mods = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Extra local mod folder names, on top of its pack's.";
              };

              # ── Network ─────────────────────────────────────────────────────
              map = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "Muldraugh, KY;West Point, KY";
                description = ''
                  The <literal>Map=</literal> list, <emphasis>semicolon</emphasis>
                  separated — note that <literal>Mods=</literal> is comma separated
                  and <literal>WorkshopItems=</literal> is also semicolon
                  separated, so this is the one key where the separator differs
                  from its neighbours.

                  null (the default) means <emphasis>derive it from the installed
                  mods</emphasis>: every <literal>media/maps/&lt;name&gt;</literal>
                  any installed mod ships is added automatically, in a
                  deterministic order, with the <option>baseMap</option> last. See
                  <option>mapOrder</option>.

                  Set an explicit string to pin it and turn detection off — which
                  you must do if your mods conflict, or if you want a map that no
                  mod ships.
                '';
              };

              baseMap = mkOption {
                type = types.str;
                default = "Muldraugh, KY";
                example = "West Point, KY";
                description = ''
                  The vanilla map, always placed LAST in the derived
                  <literal>Map=</literal>.

                  Last is deliberate: mod maps add new areas rather than patching
                  vanilla tiles, so letting the base map resolve last means any
                  genuine overlap goes in favour of vanilla — the direction that
                  cannot corrupt terrain players already know.

                  A mod shipping a map with this exact name is reported as an
                  error, because it shadows vanilla terrain.
                '';
              };

              mapOrder = mkOption {
                type = mapOrder;
                default = { };
                description = ''
                  How the derived <literal>Map=</literal> list is ordered and
                  checked for conflicts. Ignored when <option>map</option> is set.
                '';
              };

              spawn = mkOption {
                type = types.submodule {
                  options = {
                    points = mkOption {
                      type = types.listOf spawnPoint;
                      default = [ ];
                      description = ''
                        Extra spawn points, grouped by profession. Rendered into
                        <literal>&lt;servername&gt;_spawnpoints.lua</literal>.

                        Empty (the default) leaves the file alone so PZ keeps
                        whatever it generated itself.
                      '';
                    };
                    regions = mkOption {
                      type = types.listOf spawnRegion;
                      default = [ ];
                      description = ''
                        Extra spawn regions. Rendered into
                        <literal>&lt;servername&gt;_spawnregions.lua</literal>, in
                        the order given.

                        Empty (the default) leaves the file alone.
                      '';
                    };
                  };
                };
                default = { };
                description = ''
                  Custom spawn points and regions — the two files PZ lists as
                  necessary for a server to work that this module otherwise does
                  not manage. Both are regenerated by PZ when absent, so they are
                  written only when non-empty, and removed when emptied.
                '';
              };

              defaultPort = mkOption {
                type = types.port;
                default = 16261;
                defaultText = literalExpression "16261";
                description = ''
                  Primary game port (<literal>DefaultPort</literal>, UDP). Must be
                  unique across enabled servers — a clash fails evaluation with an
                  assertion naming both servers, rather than two servers each
                  binding half a socket.
                '';
              };

              udpPort = mkOption {
                type = types.port;
                default = 16262;
                defaultText = literalExpression "16262";
                description = ''
                  Direct-connection UDP port (<literal>UDPPort</literal>). PZ binds
                  two UDP ports per instance; both must be free and unique across
                  enabled servers.
                '';
              };

              rconPort = mkOption {
                type = types.port;
                default = 0;
                description = ''
                  RCON TCP port (<literal>RCONPort</literal>). The default 0 leaves
                  RCON off — open one explicitly if you want remote admin.
                '';
              };

              openFirewall = mkEnableOption "open this server's two UDP ports in the firewall";

              public = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = "Advertise in the in-game server browser. null = true.";
              };

              publicName = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Name shown in the server browser. null = the server's attribute name.";
              };

              maxPlayers = mkOption {
                type = types.int;
                default = 32;
                description = "Max concurrent players. PZ warns above 32.";
              };

              # ── Config ──────────────────────────────────────────────────────
              settings = mkOption {
                type = settings;
                default = { };
                example = {
                  PVP = true;
                  PauseEmpty = true;
                  SaveWorldEveryMinutes = 10;
                };
                description = ''
                  <literal>.ini</literal> keys this server owns, merged over its
                  pack's <option>defaultSettings</option> and re-applied on every
                  start. Only these keys are touched; PZ's world-identity keys in
                  the same file are preserved.
                '';
              };

              sandbox = mkOption {
                type = settings;
                default = { };
                example = {
                  Zombies = 3;
                  DayLength = 4;
                };
                description = ''
                  SandboxVars, merged over the pack's
                  <option>defaultSandbox</option> and rewritten on every start.
                  Unlike the <literal>.ini</literal>, this file is fully declarative
                  — PZ regenerates it, so nothing is preserved from it.
                '';
              };

              # ── Access ──────────────────────────────────────────────────────
              open = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = "null = true. false requires a populated <option>whitelist</option>.";
              };

              whitelist = mkOption {
                type = nameList;
                default = [ ];
                example = [
                  "seanc"
                  "friend"
                ];
                description = ''
                  Usernames allowed in when <option>open</option> is false.

                  <emphasis>Build 41 only.</emphasis> On Build 42 the whitelist is a
                  table in <literal>Zomboid/db/&lt;servername&gt;.db</literal>, and
                  <literal>Whitelist=</literal> is not a documented ini key — so
                  this is written only when
                  <option>compatibility.build41</option> is true, and otherwise
                  silently doing nothing. For a Build 42 server, manage it in the
                  database or in-game.
                '';
              };

              admins = mkOption {
                type = nameList;
                default = [ ];
                example = [
                  "seanc"
                ];
                description = ''
                  Admin usernames, written to <literal>Users=</literal>.

                  <emphasis>Build 41 only</emphasis>, for the same reason as
                  <option>whitelist</option>. It grants in-game admin rights; it
                  never creates the login.

                  On Build 42, to actually create the admin account use
                  <option>adminAccount</option> — there is no ini key for it.
                '';
              };

              compatibility = mkOption {
                type = types.submodule {
                  options = {
                    build41 = mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Write the Build 41 <literal>Whitelist=</literal> and
                        <literal>Users=</literal> keys.

                        Off by default because Build 42 does not document them: a
                        config that lists admins and a whitelist while having no
                        effect is worse than one that plainly does not. Turn this on
                        only for a genuine Build 41 server.
                      '';
                    };
                  };
                };
                default = { };
                description = "Legacy-key escape hatches for older PZ builds.";
              };

              adminAccount = mkOption {
                type = types.nullOr adminAccount;
                default = null;
                example = literalExpression ''
                  {
                    username = "seanc";
                    passwordFile = config.age.secrets.pz-admin.path;
                  }
                '';
                description = ''
                  Create or update a Build 42 server admin login.

                  This is the <emphasis>only</emphasis> way to get an admin account
                  on Build 42 — see the submodule for why, and for the
                  <literal>ps</literal>-visibility caveat.
                '';
              };

              secretFiles = mkOption {
                type = secretFiles;
                default = { };
                example = literalExpression ''
                  {
                    RCONPassword = config.age.secrets.pz-rcon.path;
                    DiscordToken = config.age.secrets.pz-discord-token.path;
                  }
                '';
                description = ''
                  <literal>.ini</literal> keys whose values must come from a file,
                  as <literal>Key = path</literal>. Read at start by
                  <literal>merge_ini.py</literal> and written straight into the
                  key.

                  Use this — never <option>settings</option> — for anything secret.
                  The Nix-rendered base <literal>.ini</literal> is a store path
                  (mode 444, world-readable), so a secret in
                  <option>settings</option> lands in a plaintext file any local
                  user can read. The module <emphasis>fails evaluation</emphasis> if
                  a known-secret key appears in <option>settings</option> or
                  <option>sandbox</option>.

                  Handles <literal>Password</literal> (the join password,
                  equivalent to <option>passwordFile</option>), plus
                  <literal>RCONPassword</literal>, <literal>DiscordToken</literal>
                  and <literal>WebhookAddress</literal>.
                '';
              };

              passwordFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = ''
                  File whose contents become the <literal>Password=</literal> join
                  password (e.g. an agenix secret). Read at start; the value never
                  enters a unit file, the store, or <literal>ps</literal> output.

                  Exactly equivalent to
                  <literal>secretFiles.Password = ...</literal>, and wins if both
                  are set. Kept as a separate option because the join password is
                  by far the most common secret.
                '';
              };
              # ── Process ─────────────────────────────────────────────────────

              extraArgs = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [
                  "-statistic"
                  "0"
                ];
                description = ''
                  Extra arguments appended to the server command line, after
                  <literal>-servername</literal>. For the flags PZ has no config key
                  for, such as <literal>-statistic</literal>,
                  <literal>-nosteam</literal>, <literal>-ip</literal> or
                  <literal>-cache</literal>.

                  <emphasis>Do not put credentials here.</emphasis> This list is
                  written into the systemd unit, which is world-readable — the same
                  store-leak problem <option>secretFiles</option> exists to avoid.
                  Use <option>adminAccount</option> for the admin password.

                  The flag surface moves between PZ builds, which is why this is a
                  free-form list rather than typed booleans.
                '';
              };

              upnp = mkOption {
                type = types.bool;
                default = false;
                defaultText = literalExpression "false";
                description = ''
                  <literal>UPnP=</literal> — ask the router to open the server's
                  ports automatically.

                  Defaults to <emphasis>false</emphasis>, unlike PZ's own default of
                  true. Automatic port forwarding is a poor default for a managed
                  host: it silently punches holes in a firewall that
                  <option>openFirewall</option> and the operator's own rules
                  deliberately keep closed, and it cannot work at all behind a
                  container or on a normal cloud network. Set this only when you
                  genuinely want the router mutated, and prefer
                  <option>openFirewall</option>.
                '';
              };

              selfManagedMods = mkOption {
                type = types.bool;
                default = true;
                defaultText = literalExpression "true";
                description = ''
                  <literal>SelfManagedMods=</literal> — tell PZ that the mod list is
                  managed externally and must not be rewritten by the game or by
                  in-game mod editing.

                  true (the default) is what makes the declarative modpack actually
                  stick: with it off, a player who opens the server's mod screen
                  can write a different <literal>Mods=</literal> back to the
                  <literal>.ini</literal>, and the next start would faithfully apply
                  their change over yours.
                '';
              };

              softReset = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Discard this server's world identity — <literal>Seed</literal>,
                  <literal>ResetID</literal>, <literal>ServerPlayerID</literal> and
                  friends — so PZ generates a fresh world on the next start.

                  <emphasis>Destructive, and applied on every start while
                  true.</emphasis> The NixOS module clears it once
                  <command>systemd.nixos.reboot</command> takes effect, so this is a
                  declarative "reset my world" switch; leave it on and every restart
                  starts a new world. The <literal>Saves/</literal> directory is
                  left alone — the old world stays on disk to recover.
                '';
              };

              betaBranch = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "legacy41";
                description = ''
                  Steam beta branch to install the dedicated server from, passed as
                  <literal>-beta &lt;branch&gt;</literal>. null (the default) means
                  the stable branch.

                  Per-server, but applied by the <emphasis>shared</emphasis> install
                  unit, so all servers on one install necessarily share a branch.
                  Set it on every server, or on none.
                '';
              };

              jvmOpts = mkOption {
                type = types.str;
                default = "-Xmx4G -Xms2G";
                example = "-Xmx8G -Xms4G -XX:+UseZGC";
                description = ''
                  JVM flags for the server process. Passed via
                  <literal>PZ_JVM_OPTS</literal> and placed *before* the
                  <literal>--</literal> separator the launcher inserts, which is
                  what routes them to the JVM rather than to the game.

                  These flags are the only way to set the heap: the vendor's
                  <literal>ProjectZomboid64.json</literal> ships a hardcoded
                  <literal>-Xmx8g</literal>, and <literal>start-server.sh</literal>
                  offers no other hook. Free-form because the flag surface moves
                  between PZ builds. Sizing matters — <literal>start-server.sh</literal>
                  always exits <literal>0</literal>, so an OOM-killed JVM is not
                  distinguishable from a clean quit by exit status alone.
                '';
              };

              javaAgent = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      jar = mkOption {
                        type = types.path;
                        description = ''
                          The agent JAR. Loaded with <literal>-javaagent:</literal>
                          before any mod class is on the classpath.
                        '';
                      };
                      args = mkOption {
                        type = types.str;
                        default = "";
                        description = ''
                          Agent arguments, joined with commas. A leading
                          <literal>=</literal> is added automatically; leave this
                          empty for an agent that takes none.
                        '';
                      };
                    };
                  }
                );
                default = null;
                example = literalExpression ''
                  {
                    jar = pkgs.zombiebuddy;
                    args = "policy=allow-all,frontend=console,verbosity=1";
                  }
                '';
                description = ''
                  A Java agent to load into the server JVM, prepended to
                  <option>jvmOpts</option>.

                  This is the hook <emphasis>Java-mod frameworks</emphasis> need.
                  Project Zomboid's own mod system is Lua-only; frameworks such as
                  ZombieBuddy work by attaching a JVM agent that patches game
                  classes, and the mods they enable ship their JARs *inside* their
                  own Workshop folder (referenced by <literal>javaJarFile</literal>
                  in <literal>mod.info</literal>), so nothing needs copying — only
                  the agent has to reach the JVM.

                  <emphasis>Headless servers must set a policy.</emphasis>
                  Frameworks default to prompting for approval per unknown JAR on
                  stdin, which a systemd unit has no one to answer: the server
                  appears to hang at boot. Pass a non-prompting policy
                  (ZombieBuddy: <literal>policy=allow-all</literal> or
                  <literal>deny-new</literal>, plus
                  <literal>frontend=console</literal>).
                '';
              };

              autoStart = mkOption {
                type = types.bool;
                default = true;
                description = "Start at boot.";
              };

              restart = mkOption {
                type = types.str;
                default = "always";
                description = ''
                  systemd <literal>Restart</literal> policy.

                  The default is <literal>always</literal> rather than
                  <literal>on-failure</literal> for a specific reason: stopping a PZ
                  server cleanly sends <literal>quit</literal> down the console, which
                  makes the JVM exit <literal>0</literal>. Under
                  <literal>on-failure</literal> that is a *success*, so the unit
                  would not come back — including after a deliberate
                  <literal>systemctl stop</literal>-then-boot. Use
                  <literal>on-failure</literal> only if you want a crash-looping
                  server to stay down.
                '';
              };

              managementSystem = mkOption {
                type = managementSystem;
                # Inherit the top-level backend by default. A submodule option's
                # default is otherwise independent of its parent's, so `default = { }`
                # here would silently mean "neither backend" and trip this module's
                # own exactly-one-backend assertion on every server.
                default = config.services.project-zomboid-servers.managementSystem;
                defaultText = literalExpression "services.project-zomboid-servers.managementSystem";
                description = ''
                  How this server's console is reached. Defaults to the top-level
                  <option>services.project-zomboid-servers.managementSystem</option>;
                  override per server to mix backends.
                '';
              };

              hardware = mkOption {
                type = hardware;
                default = { };
                description = "cgroup resource caps and scheduler niceness for this server.";
              };

              extraServiceConfig = mkOption {
                type = types.attrs;
                default = { };
                example = {
                  LimitNOFILE = 65536;
                };
                description = ''
                  Extra <literal>serviceConfig</literal> merged onto this server's
                  unit. Note the unit runs under <literal>steam-run</literal> (bwrap),
                  so avoid sandboxing directives that break a user-namespace FHS
                  environment.
                '';
              };

              webConsole = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Give this server a ttyd web console. Also requires
                  <option>services.project-zomboid-servers.web.enable</option>.
                '';
              };

              port = mkOption {
                type = types.nullOr types.port;
                default = null;
                description = ''
                  Web console port. null = assign one from
                  <option>web.portBase</option> in sorted server order, which keeps
                  ports stable as long as you do not rename servers.
                '';
              };

              # ── Client-host files ──────────────────────────────────────────
              # Deliberately INDEPENDENT of `enable`. `enable` decides whether the
              # dedicated server exists on this host; a client host is a separate
              # way to run the same pack, and the common case is exactly the one
              # where `enable = false` — the pack drives the in-game Host button
              # and no dedicated server is installed at all.
              clientHost = {
                enable = mkEnableOption ''
                  client-host files for this server, for Project Zomboid's in-game
                  Host button (see <option>clientHosts</option>)
                '';

                name = mkOption {
                  type = types.str;
                  default = "servertest";
                  description = ''
                    The client-side server name. Project Zomboid names both the
                    config and the save after it:
                    <literal>Zomboid/Server/&lt;name&gt;.ini</literal> and
                    <literal>Zomboid/Saves/Multiplayer/&lt;name&gt;</literal>.
                    <literal>servertest</literal> is the name the game's Host
                    screen uses by default, so changing it makes a NEW world
                    rather than reusing the existing one.
                  '';
                };
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Per-server definitions. Each enabled server becomes a
        <literal>project-zomboid-&lt;name&gt;</literal> service and, by default, a
        matching <literal>.socket</literal> for its console.
      '';
    };

    managementSystem = mkOption {
      type = managementSystem;
      default = {
        systemd-socket.enable = true;
      };
      defaultText = literalExpression "{ systemd-socket.enable = true; }";
      description = ''
        Default console backend for servers that do not override it. Exactly one
        of <literal>systemd-socket</literal> or <literal>tmux</literal> may be
        enabled (asserted).
      '';
    };

    startLimitIntervalSec = mkOption {
      type = types.int;
      default = 120;
      description = ''
        Crash-loop window for the server units. Combined with
        <option>startLimitBurst</option> this stops a server that cannot start
        (bad port, missing install, OOM) from restart-storming the host.
      '';
    };

    startLimitBurst = mkOption {
      type = types.int;
      default = 5;
      description = "Restarts allowed within <option>startLimitIntervalSec</option>.";
    };

    # ── Derived / read-only ──────────────────────────────────────────────────

    webConsoleUpstreams = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Suggested upstream name, unique per server.";
            };
            port = mkOption {
              type = types.port;
              description = "Loopback port the console listens on.";
            };
            path = mkOption {
              type = types.str;
              description = "URL path prefix, with a trailing slash.";
            };
            stripPrefix = mkOption {
              type = types.bool;
              default = true;
              description = "Whether the proxy should strip <option>path</option> before proxying (required by ttyd).";
            };
            displayName = mkOption {
              type = types.str;
              default = "";
              description = "Human-readable label for proxy UIs.";
            };
          };
        }
      );
      # Deliberately NO `default`. A `readOnly` option may have exactly one
      # definition, and `default = [ ]` counts as one — so declaring a default
      # *and* setting it in config.nix fails evaluation with "The option ... is
      # read-only, but it's set multiple times". config.nix is the only definer.
      readOnly = true;
      description = ''
        READ-ONLY. One entry per web console, derived from the enabled servers.

        This project deliberately does not wire the consoles into any particular
        reverse-proxy module — a standalone flake cannot depend on a consumer's
        private option namespace. Map this into whatever you use:

        <programlisting>
        proxy.upstreams = lib.mkMerge (map (u: {
          inherit (u) port path stripPrefix displayName;
          name = u.name;
        }) config.services.project-zomboid-servers.webConsoleUpstreams);
        </programlisting>
      '';
    };

    clientHosts = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            serverName = mkOption {
              type = types.str;
              description = "The client-side server name — the `<name>.ini` basename.";
            };
            prepare = mkOption {
              type = types.path;
              description = ''
                A runnable script that seeds the client's Project Zomboid home
                from this server's config. Takes its paths from the environment:

                <programlisting>
                PZ_CLIENT_ZOMBOID=~/Zomboid \
                PZ_SERVER_DIR=/mnt/data/project-zomboid/server \
                PZ_CLIENT_WORKSHOP=~/.local/share/Steam/steamapps/workshop/content/108600 \
                  /nix/store/…-project-zomboid-&lt;name&gt;-client-host
                </programlisting>

                <literal>PZ_CLIENT_ZOMBOID</literal> is required;
                <literal>PZ_SERVER_DIR</literal> and
                <literal>PZ_CLIENT_WORKSHOP</literal> are optional and, when both
                are set, symlink the shared Workshop download into the client's
                Steam library so the mods are not downloaded twice.
              '';
            };
            iniFile = mkOption {
              type = types.path;
              description = ''
                The Nix-rendered base `<name>.ini` (a store file), BEFORE the
                world-identity merge. Normally handed to <option>prepare</option>
                rather than installed directly — installing it verbatim would
                overwrite Seed / ServerPlayerID on an existing world.
              '';
            };
            sandboxFile = mkOption {
              type = types.path;
              description = "The Nix-rendered `<name>_SandboxVars.lua` (a store file).";
            };
            mods = mkOption {
              type = types.listOf types.str;
              description = "The resolved `Mods=` list, for a client that installs its own config.";
            };
            workshopItems = mkOption {
              type = types.listOf types.str;
              description = "The resolved `WorkshopItems=` list (Steam Workshop ids).";
            };
          };
        }
      );
      # No `default` — read-only options may have exactly one definition and
      # `default = { }` would count as one. services.nix is the only definer.
      readOnly = true;
      description = ''
        READ-ONLY. One entry per server with
        <option>servers.&lt;name&gt;.clientHost.enable</option> = true.

        This exists so a pack can drive BOTH ways of hosting a world from one
        description. A dedicated server (the systemd units below) and the game's
        in-game <emphasis>Host</emphasis> button run the same `.ini`, the same
        SandboxVars and the same mod list; only the two hosts' file locations
        differ. Rendering the client side here means the mod list is never
        written down twice, and cannot drift.

        Nothing is installed by this module: the client's Zomboid home is a
        user-level path (`~/Zomboid`) that a system module cannot own. Run
        <option>prepare</option> from wherever the client user is configured —
        e.g. a Home Manager <literal>home.activation</literal> hook.
      '';
    };

    # ── Web consoles ─────────────────────────────────────────────────────────

    web = {
      enable = mkEnableOption "ttyd web consoles for servers with <option>webConsole</option> = true";

      portBase = mkOption {
        type = types.port;
        default = 7682;
        description = ''
          First auto-assigned console port. The default starts at 7682 because
          7681 is conventionally taken by another ttyd service.
        '';
      };

      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Interface to bind. Defaults to loopback — expose it via a proxy or a tailnet IP, not directly.";
      };

      user = mkOption {
        type = types.str;
        default = "project-zomboid-web";
        description = ''
          User the consoles run as. Added to the server group and granted scoped,
          password-less sudo for `systemctl {start,stop,restart,status}` on the PZ
          units only.
        '';
      };

      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HTTP basic-auth username. Requires <option>passwordFile</option>.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File holding the HTTP basic-auth password (e.g. an agenix secret).";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open the console ports. Off by default — consoles are meant to sit behind a proxy.";
      };
    };
  };
}
