# modules/options/servers.nix
#
# `servers.<name>` and the default console backend.
{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    literalExpression
    ;
  inherit (import ./types.nix { inherit lib; })
    hardware
    managementSystem
    workshopMod
    spawnPoint
    spawnRegion
    mapOrder
    secretFiles
    adminAccount
    settings
    nameList
    ;
in
{
  options.services.project-zomboid-servers = {
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

              localMods = mkOption {
                type = types.attrsOf types.path;
                default = { };
                example = literalExpression ''
                  {
                    # folder name = directory holding the mod (its mod.info)
                    BritasArmorPack = /srv/mods/BritasArmorPack;
                  }
                '';
                description = ''
                  Non-Workshop mods, as <literal>folder-name = directory</literal>.
                  Each directory is symlinked into the server's
                  <literal>Zomboid/mods</literal>, and the key is added to
                  <literal>Mods=</literal> automatically — so declaring the
                  directory here is the only mention it needs.

                  <emphasis>This is the fallback for a mod that cannot be
                  downloaded</emphasis> — a private or mature-gated Workshop item
                  (see <option>steamLogin</option>), or a modworkshop.net release.
                  Download the mod on a client, or obtain its files elsewhere, and
                  point this at the folder that contains its
                  <literal>mod.info</literal>. The key must be the mod's
                  <literal>id=</literal> value, the same string
                  <literal>Mods=</literal> takes.

                  Only symlinks this module creates are removed when
                  <option>prune</option> is on; a real directory dropped into
                  <literal>Zomboid/mods</literal> by hand is never touched.
                '';
              };

              # ── Network ─────────────────────────────────────────────────────
              map = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "Muldraugh, KY;West Point, KY";
                description = ''
                  The <literal>Map=</literal> list, <emphasis>semicolon</emphasis>
                  separated. <literal>Mods=</literal> and
                  <literal>WorkshopItems=</literal> are semicolon separated too —
                  Build 42 splits <literal>Mods=</literal> on <literal>;</literal>
                  only, so a comma-joined list loads nothing at all.

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

                  RCON also needs a password: PZ starts the listener only when the
                  port is non-zero <emphasis>and</emphasis>
                  <literal>RCONPassword</literal> is non-empty, so set
                  <option>secretFiles</option><literal>.RCONPassword</literal>
                  alongside this. A port without a password is reported as an
                  evaluation warning (and RCON stays off), because otherwise it
                  looks configured and silently does nothing.
                '';
              };

              openRconFirewall = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Open <option>rconPort</option> in the firewall.

                  Off by default. RCON is plaintext TCP, and the dashboard and
                  idle-stop check read it over loopback, so the module has no
                  reason to expose it. Set this only when an external RCON client
                  must reach the port; prefer a private network or a firewall
                  rule restricted to that client's address.
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
                # Build 42 (verified on 42.21.0) documents `Min: 1 Max: 254
                # Default: 32` in its own generated .ini. The wiki's 1–100 is out
                # of date, so the bound is the server's, not the page's.
                type = types.ints.between 1 254;
                default = 32;
                description = ''
                  Max concurrent players (<literal>MaxPlayers</literal>). This
                  excludes admins. PZ warns above 32 — map streaming and sync
                  degrade — and the build caps it at 254.
                '';
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

                  This is for keys the module does not otherwise own. These keys
                  have their own options and are <emphasis>rejected</emphasis>
                  here rather than rendered twice:
                  <literal>DefaultPort</literal>,
                  <literal>UDPPort</literal>,
                  <literal>RCONPort</literal>,
                  <literal>Public</literal>,
                  <literal>PublicName</literal>,
                  <literal>MaxPlayers</literal>,
                  <literal>Open</literal>,
                  <literal>Map</literal>,
                  <literal>Mods</literal>,
                  <literal>WorkshopItems</literal>,
                  <literal>UPnP</literal> and
                  <literal>SelfManagedMods</literal> (Build 41 only — the key does
                  not exist in Build 42), plus <literal>Whitelist</literal> /
                  <literal>Users</literal> when
                  <option>compatibility.build41</option> is set.

                  A value cannot contain a newline: the <literal>.ini</literal>
                  format has no escape for one. Use PZ's literal
                  <literal>&lt;LINE&gt;</literal> token where the key supports it
                  (e.g. <literal>ServerWelcomeMessage</literal>).
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

                  Build 42 moved several groups into nested Lua tables
                  (<literal>ZombieLore</literal>, <literal>ZombieConfig</literal>,
                  <literal>MultiplierConfig</literal>, <literal>Map</literal>,
                  <literal>Basement</literal>). Those keys must be written in
                  dotted form, because a flat key is an unknown option and is
                  ignored:

                  <programlisting>
                    sandbox."ZombieConfig.PopulationStartMultiplier" = 1.5;
                    sandbox."ZombieLore.Speed" = 2;
                  </programlisting>

                  A flat <literal>PopulationStartMultiplier</literal> is rejected
                  with the dotted spelling to use. The one ambiguous name is
                  <literal>Farming</literal>: flat is the farming-speed enum,
                  dotted (<literal>"MultiplierConfig.Farming"</literal>) is the XP
                  multiplier.

                  The renderer writes the version header automatically
                  (<literal>VERSION = 6</literal> for 42.21). Do not omit it:
                  without it PZ treats the file as version 0 and migrates values
                  (e.g. <literal>DayLength = 8</literal> becomes 14).
                '';
              };

              sandboxNamespaces = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [
                  "Bandits"
                  "TrueActions"
                ];
                description = ''
                  Mod-defined SandboxVars groups, so their options can be set
                  through <option>sandbox</option>.

                  A mod ships <filename>media/sandbox-options.txt</filename>
                  declaring <literal>option Bandits.Enabled</literal>; PZ then
                  reads <literal>SandboxVars.Bandits.Enabled</literal>. Declare
                  the first part here and write the option with a dotted key:

                  <programlisting>
                    sandboxNamespaces = [ "Bandits" ];
                    sandbox."Bandits.Enabled" = true;
                  </programlisting>

                  Each namespace is rendered as a nested Lua table, so it must be
                  a Lua identifier and must not reuse a vanilla B42 table
                  (<literal>ZombieLore</literal>, <literal>ZombieConfig</literal>,
                  <literal>MultiplierConfig</literal>, <literal>Map</literal>,
                  <literal>Basement</literal>). Undeclared namespaces are still
                  rejected, which is what keeps a typo from becoming a silent
                  no-op; the option names inside a namespace are the mod's, so they
                  are not checked against a list.

                  A pack may declare the same list; the server's is added to it.
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

                  The file must be readable by the server's service user
                  (<option>user</option>), not only by root: the prep script runs
                  as that user and merges the value into the <literal>.ini</literal>.
                  An agenix secret with the default <literal>0400</literal>
                  root ownership stops the server at
                  <literal>cannot read secret file</literal>.
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

                  <emphasis>Build 41 only.</emphasis> Build 42 has no UPnP
                  implementation: the 42.21 game jar contains no UPnP class at
                  all and <literal>ServerOptions.uPnp</literal> is never read, so
                  the key is a silent no-op there. The resolver emits an
                  evaluation warning when this is set on a Build 42 server;
                  forward <option>defaultPort</option>/<option>udpPort</option> on
                  the router instead, or map them with a UPnP client such as
                  <literal>miniupnpc</literal>.

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

                  <emphasis>Build 41 only.</emphasis> The key does not exist in
                  Build 42: it is absent from the 42.21 game jar and from the
                  <literal>.ini</literal> the server writes back, so a Build 42
                  server never reads it. The renderer therefore omits it for a
                  Build 42 target rather than writing a key that does nothing
                  (it is still written when
                  <option>compatibility.build41</option> is set).
                '';
              };

              softReset = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Discard this server's world identity — <literal>Seed</literal>,
                  <literal>ResetID</literal>, <literal>ServerPlayerID</literal> and
                  friends — so every client must create a new character on its next
                  join.

                  <emphasis>The map is NOT regenerated.</emphasis>
                  <literal>Saves/</literal> is left untouched, so terrain,
                  constructions, loot and vehicles all persist; only the identity
                  keys are cleared and a new seed value is generated. PZ itself
                  notes that a genuinely new world also requires deleting
                  <literal>map_worldgen.bin</literal> from the save directory —
                  this option deliberately does not, so the old world stays
                  recoverable and an accidental flip is not catastrophic.

                  <emphasis>Destructive, and applied on every start while
                  true.</emphasis> Nothing clears it for you — a Nix option is
                  static — so set it back to <literal>false</literal> and rebuild
                  once the reroll has happened. Leaving it on rerolls clients again
                  on every restart.
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
                description = ''
                  Start at boot.

                  Independent of <option>schedule.start</option>: a server with
                  both starts at boot <emphasis>and</emphasis> at each scheduled
                  time. Set this to <literal>false</literal> when the server
                  should only be up during the scheduled windows.
                '';
              };

              schedule = mkOption {
                type = types.submodule {
                  options = {
                    start = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      example = [
                        "*-*-* 22:00:00"
                        "Sat,Sun 10:00:00"
                      ];
                      description = ''
                        systemd <literal>OnCalendar</literal> expressions that
                        start this server. Empty (the default) means no start
                        timer is generated.

                        Each entry is passed straight to systemd, so the usual
                        calendar syntax applies: <literal>"22:00"</literal> is
                        daily, <literal>"*-*-* 22:00:00"</literal> is the same
                        with an explicit date, and
                        <literal>"Sat,Sun 10:00:00"</literal> is weekends only.
                        See <citerefentry><refentrytitle>systemd.time</refentrytitle>
                        <manvolnum>7</manvolnum></citerefentry>.

                        The timer starts the server service; starting an
                        already-running server is a no-op. It does not stop the
                        server — use <option>idleStop</option> or
                        <literal>systemctl stop</literal> for that.
                      '';
                    };

                    persistent = mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Catch up on a missed start after the machine was off at
                        the scheduled time. Off by default: a game server
                        starting late because the host was rebooting is usually
                        worse than waiting for the next window.
                      '';
                    };
                  };
                };
                default = { };
                description = ''
                  Scheduled start times. See <option>schedule.start</option>.
                '';
              };

              idleStop = mkOption {
                type = types.submodule {
                  options = {
                    enable = mkEnableOption "stopping this server after it has been empty for a while";

                    timeout = mkOption {
                      type = types.strMatching "[0-9]+[smhd]";
                      default = "30m";
                      example = "2h";
                      description = ''
                        How long the server may stay empty before it is stopped.
                        One number and one unit: <literal>90s</literal>,
                        <literal>30m</literal>, <literal>2h</literal> or
                        <literal>1d</literal>.

                        The check runs once a minute. It is deliberately
                        conservative: an unreachable RCON (the server is still
                        loading 400 Workshop items, or RCON crashed) is
                        <emphasis>not</emphasis> treated as empty, and the player
                        count is queried again immediately before stopping so a
                        player who joins in between is not kicked.

                        <emphasis>Requires RCON.</emphasis> Set
                        <option>rconPort</option> and
                        <option>secretFiles.RCONPassword</option>; evaluation
                        fails otherwise. The timer is a root oneshot because it
                        stops a system unit, but it needs no capability of its
                        own: the port is baked in at build time and the password
                        arrives as a systemd credential, so it never opens the
                        data directory or the rendered <literal>.ini</literal>
                        (which a capability-less root cannot read — doing so
                        made the whole check a silent no-op).
                      '';
                    };
                  };
                };
                default = { };
                description = ''
                  Stop the server after it has had no players for
                  <option>idleStop.timeout</option>. Useful together with
                  <option>schedule.start</option> for a server that should only
                  run while people are actually playing.
                '';
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

                preset = {
                  enable = mkEnableOption ''
                    a managed mod preset in the client's vanilla Mods menu
                    (<filename>Zomboid/Lua/pz_modlist_settings.cfg</filename>)
                  '';

                  name = mkOption {
                    type = types.str;
                    default = "";
                    description = ''
                      Preset name shown in the Mods menu. Empty means the server
                      attribute name — <literal>viewpoint</literal> for
                      <literal>servers.viewpoint</literal>.

                      The preset enables the pack's ordered <literal>mods</literal>
                      list. It is merged into the file, so the player's own
                      presets and favourites survive. Project Zomboid re-orders
                      the list when the preset is applied, using each mod's
                      <literal>require=</literal> only, so the written order is
                      informative rather than a promise. Mods that are not
                      downloaded are reported by the game's “missed mods” window
                      and simply left off.
                    '';
                  };
                };

                openFirewall = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Open this client host's two UDP ports in the firewall.

                    The server-level <option>openFirewall</option> cannot cover a
                    client host: it is wired from the ENABLED servers only, and
                    the usual client-host setup has <literal>enable = false</literal>
                    with no unit at all. The game's own Host button binds
                    <option>defaultPort</option> and <option>udpPort</option> when
                    it starts, so set this when other players must reach a world
                    hosted from the client.

                    Note that PZ also tells joining clients its
                    <emphasis>public</emphasis> address (the co-op server sends
                    <literal>server-address@&lt;public-ip&gt;:&lt;defaultPort&gt;</literal>),
                    so opening the ports is necessary but not sufficient behind a
                    NAT router — the router has to forward the same two ports, or
                    <option>upnp</option> has to work. See the troubleshooting
                    guide.
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
  };
}
