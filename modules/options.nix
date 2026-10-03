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

  # A `.ini` / SandboxVars value. Kept open (oneOf) so any PZ setting can be set
  # without this module enumerating PZ's ~200 keys.
  iniSetting = types.oneOf [
    types.bool
    types.int
    types.float
    types.str
  ];
  settings = types.attrsOf iniSetting;

  # Comma-separated username list (whitelist / admins).
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
                Use this for modworkshop.net mods, which are not Workshop items.
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
                type = types.str;
                default = "Muldraugh, KY";
                description = "Map folder name under the install's <literal>media/maps</literal>.";
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
                description = "Usernames allowed in when <option>open</option> is false.";
              };

              admins = mkOption {
                type = nameList;
                default = [ ];
                description = ''
                  Admin usernames (<literal>Users=</literal> in the .ini). These are
                  Steam account names.

                  Note: on Build 42 the *admin login* is a row in
                  <literal>Zomboid/db/&lt;servername&gt;.db</literal> and its first-run
                  password is set by an interactive prompt, not by this module.
                  Listing a name here grants in-game admin; it does not create the
                  login. See README 'Build 42 admin accounts'.
                '';
              };

              passwordFile = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = ''
                  File whose contents become the <literal>Password=</literal> join
                  password (e.g. an agenix secret). Read at start; the value never
                  enters a unit file or <literal>ps</literal> output.
                '';
              };

              # ── Process ─────────────────────────────────────────────────────
              jvmOpts = mkOption {
                type = types.str;
                default = "-Xmx4G -Xms2G";
                example = "-Xmx8G -Xms4G -XX:+UseZGC";
                description = ''
                  JVM flags for the server process. Passed via
                  <literal>PZ_JVM_OPTS</literal> and injected *ahead of* the
                  vendor launcher, because <literal>start-server.sh</literal> sets
                  its own hardcoded <literal>-Xms/-Xmx</literal> and ignores anything
                  set after it. Free-form because the flag surface moves between
                  PZ builds.
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
