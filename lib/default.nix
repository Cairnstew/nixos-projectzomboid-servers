# lib/default.nix
#
# Shared, NixOS-module-free helpers for Project Zomboid dedicated servers:
#   - rendering the `<name>.ini` and `<name>_SandboxVars.lua` files PZ reads,
#   - resolving a server's effective config against a modpack,
#   - `mkProxyUpstreams`, so a consumer can wire the web consoles into whatever
#     reverse proxy it uses without this project depending on that module.
#
# Everything here is pure: no `config`, no `pkgs`. `self.lib` exposes it.
{ lib }:

let
  inherit (lib)
    concatStringsSep
    concatMapStringsSep
    filter
    mapAttrsToList
    removeAttrs
    unique
    ;

  # ── Keys that must never be written to a store file ─────────────────────────
  # The Nix-rendered base `.ini` is a `pkgs.writeText` store path: mode 444,
  # world-readable, and greppable by anyone who can read /nix/store. A secret
  # routed through `settings` therefore ends up in a plaintext file every local
  # user can read, which is how a join password leaks.
  #
  # These keys are only settable through `secretFiles` (a Key -> path attrset),
  # whose values are read by merge_ini.py at start time. The module ASSERTS on
  # these keys appearing in `settings` or `sandbox`; they are also filtered out
  # of the render below, so a bare module import that bypasses the assertion
  # still cannot leak one.
  secretIniKeys = [
    "Password"
    "RCONPassword"
    "DiscordToken"
    "WebhookAddress"
  ];

  # ── Value rendering ─────────────────────────────────────────────────────────
  # A `.ini` value. PZ's own ini writer emits bare values, so strings with inner
  # spaces are safe unquoted; booleans render as true/false.
  renderIniValue = v: if builtins.isBool v then (if v then "true" else "false") else toString v;

  quoteLua = s: "\"${lib.escape [ "\"" "\\" ] s}\"";

  renderLuaValue =
    v:
    if builtins.isBool v then
      (if v then "true" else "false")
    else if builtins.isInt v || builtins.isFloat v then
      toString v
    else
      quoteLua v;

  # ── `<servername>_SandboxVars.lua` ──────────────────────────────────────────
  # Fully declarative: PZ regenerates this file itself, so we own it outright
  # (unlike the `.ini`, which carries world-identity keys we must preserve).
  renderSandbox =
    { settings }:
    let
      body = concatStringsSep ",\n" (mapAttrsToList (n: v: "    ${n} = ${renderLuaValue v}") settings);
    in
    ''
      SandboxVars = {
      ${body}
      }
    '';

  # ── `servertest_spawnpoints.lua` ────────────────────────────────────────────
  # `points` is a list of `{ pos = [ x y z ]; profession ? "unemployed"; }`.
  #
  # PZ regenerates this file itself when it is absent, so we write it only when
  # there is something to say — an empty SpawnPoints() would be an empty
  # override of whatever the game would otherwise generate.
  #
  # Professions are grouped preserving FIRST-APPEARANCE order: deterministic
  # (a given list always renders identically) while still respecting the order
  # the list was written in.
  #
  # Built by explicit string concatenation rather than a `''` template with
  # interpolated fragments. Nix strips a template's minimum indentation but does
  # NOT re-indent an interpolated value, so a multi-line fragment lands with
  # whatever indentation its own template had — which put closing braces at
  # column 0. Lua does not care, but these files are read by humans debugging a
  # spawn, and the fragility is not worth the cleverness.
  renderSpawnPoints =
    points:
    let
      professionOf = p: if p ? profession then p.profession else "unemployed";
      professions = unique (map professionOf points);

      renderPoint =
        p:
        let
          pos = p.pos;
        in
        "            { posX = ${toString (builtins.elemAt pos 0)}, posY = ${toString (builtins.elemAt pos 1)}, posZ = ${toString (builtins.elemAt pos 2)} }";

      # A Lua table key for a profession name.
      #
      # PZ's own generated file writes `unemployed = {` with a BARE identifier, so
      # match that for names that are valid Lua identifiers — which also keeps the
      # file diff-comparable against one PZ has generated. Anything else (a space,
      # a dash) must be bracket-quoted: a bare `"some name" = {` is a syntax error,
      # because Lua reads the quoted string as a positional value and then finds an
      # `=` where it expects `,` or `}`. Caught by parsing the output with a real
      # Lua interpreter, not by reading it.
      luaKey =
        name: if builtins.match "^[_A-Za-z][_A-Za-z0-9]*$" name != null then name else "[${quoteLua name}]";

      renderGroup =
        prof:
        concatStringsSep "\n" (
          [ "        ${luaKey prof} = {" ]
          # Comma-separated, not newline-separated: consecutive table
          # constructors in a Lua table need the separator, and a bare `}` then
          # `{` on the next line is a syntax error. (Verified against a real Lua
          # parser — it is not something to eyeball.)
          #
          # The result is wrapped in a list because it is spliced with `++`, which
          # requires lists on both sides; `concatMapStringsSep` returns a string.
          ++ [
            (concatMapStringsSep ",\n" renderPoint (filter (p: (professionOf p) == prof) points))
          ]
          ++ [ "        }" ]
        );

      # `lib.optional` already wraps its argument in a list — passing an extra
      # `[ ]` around it nests a list inside a list, which then fails when
      # concatStringsSep tries to use it as a string.
      body = [
        "function SpawnPoints()"
        "    return {"
      ]
      ++ lib.optional (points != [ ]) (concatStringsSep ",\n" (map renderGroup professions))
      ++ [
        "    }"
        "end"
      ];
    in
    concatStringsSep "\n" body;

  # ── `servertest_spawnregions.lua` ───────────────────────────────────────────
  # `regions` is a list of `{ name, file; }`. Order is the user's, because which
  # region wins is a gameplay decision rather than something to sort out.
  renderSpawnRegions =
    regions:
    let
      body = [
        "function SpawnRegions()"
        "    return {"
      ]
      ++ lib.optional (regions != [ ]) (
        concatStringsSep ",\n" (
          map (r: "        { name = ${quoteLua r.name}, file = ${quoteLua r.file} }") regions
        )
      )
      ++ [
        "    }"
        "end"
      ];
    in
    concatStringsSep "\n" body;

  # ── `<servername>.ini` ──────────────────────────────────────────────────────
  # `Key=value` lines for the keys the module owns.
  #
  # NOTE: these lines are only used to *create* a missing `.ini`. An existing one
  # is updated key-by-key via scripts/merge_ini.py, because PZ stores world
  # identity (Seed, ResetID, ServerPlayerID, Password, LastModified, ...) in the
  # same file and rewriting it wholesale would renumber every world.
  renderIniLines =
    {
      settings,
      mods,
      workshopItems,
      # Build 42 moved the admin login and the whitelist into
      # `Zomboid/db/<servername>.db`; `Whitelist=` and `Users=` are no longer
      # documented ini keys, so they are NOT written unless a Build 41 server
      # explicitly asks for them. Writing them by default left a config that
      # looks authoritative and does nothing.
      legacyBuild41 ? false,
      whitelist ? [ ],
      admins ? [ ],
    }:
    let
      key = n: v: "${n}=${renderIniValue v}";
      # `Map=` is omitted when `settings` has no `map`, which is the signal that
      # map auto-detection is in charge: the resolved value depends on which
      # mods are actually installed, so it cannot be rendered at eval time. The
      # prep script computes it and passes it to merge_ini.py instead.
      owned = [
        "defaultPort"
        "udpPort"
        "rconPort"
        "public"
        "publicName"
        "maxPlayers"
        "open"
        "map"
        "mods"
        "workshopItems"
      ]
      ++ lib.optional legacyBuild41 "whitelist"
      ++ lib.optional legacyBuild41 "admins"
      # Defence in depth for the store-leak control: even if the assertion is
      # bypassed, these can never reach the rendered file.
      ++ secretIniKeys;

      # The keys the module owns, always written first and in this order.
      ordered = [
        (key "DefaultPort" settings.defaultPort)
        (key "UDPPort" settings.udpPort)
        (key "RCONPort" settings.rconPort)
        (key "Public" settings.public)
        (key "PublicName" settings.publicName)
        (key "MaxPlayers" settings.maxPlayers)
        (key "Open" settings.open)
      ]
      ++ lib.optional (settings ? map) (key "Map" settings.map)
      ++ [
        (key "Mods" (concatStringsSep "," mods))
        (key "WorkshopItems" (concatStringsSep ";" workshopItems))
      ]
      ++ lib.optional legacyBuild41 (key "Whitelist" (concatStringsSep "," whitelist))
      ++ lib.optional legacyBuild41 (key "Users" (concatStringsSep "," admins));
    in
    ordered ++ mapAttrsToList key (removeAttrs settings owned);

  # ── Modpack resolution ──────────────────────────────────────────────────────
  # Merge order: an empty pack  <  the named modpack's defaults  <  the server's
  # inline values. Returns everything the unit, the `.ini` merge and the
  # Workshop download step need.
  #
  # `packs` is an attrset of modpack name -> pack. An unknown name throws with
  # the list of packs that DO exist, because a typo here is otherwise silent.
  emptyPack = {
    description = "";
    workshopMods = [ ];
    mods = [ ];
    defaultSettings = { };
    defaultSandbox = { };
  };

  resolveServer =
    packs: name: srv:
    let
      knownPacks = builtins.attrNames packs;
      pack =
        if srv.modpack != null then
          (
            if builtins.hasAttr srv.modpack packs then
              packs.${srv.modpack}
            else
              throw ''
                project-zomboid-servers: server `${name}` references modpack
                `${srv.modpack}`, which does not exist. Available modpacks: ${
                  if knownPacks == [ ] then "(none)" else concatStringsSep ", " knownPacks
                }.
              ''
          )
        else
          emptyPack;
      serverName = if srv.name != "" then srv.name else name;

      # `Map=` resolution, in precedence order: the server's own `map`, then a
      # modpack that pins one, then nothing at all — which means auto-detection.
      #
      # Auto-detection is the default because `Map=` is the one config key that
      # cannot be written down statically: a map only exists if a mod ships it,
      # and which mods are installed is not known until steamcmd has run. See
      # scripts/pz_maps.py.
      packMap = if pack.defaultSettings ? map then pack.defaultSettings.map else null;
      pinnedMap = if srv.map != null then srv.map else packMap;

      # The `.ini` settings: pack defaults, then the module-owned keys, then the
      # server's own inline overrides.
      settings = lib.recursiveUpdate (
        pack.defaultSettings
        // {
          defaultPort = srv.defaultPort;
          udpPort = srv.udpPort;
          rconPort = srv.rconPort;
          maxPlayers = srv.maxPlayers;
          public = if srv.public != null then srv.public else true;
          publicName = if srv.publicName != null then srv.publicName else name;
          open = if srv.open != null then srv.open else true;
          UPnP = srv.upnp;
          SelfManagedMods = srv.selfManagedMods;
        }
        // lib.optionalAttrs (pinnedMap != null) { map = pinnedMap; }
      ) srv.settings;

      description =
        if srv.description != "" then
          srv.description
        else if pack.description != "" then
          "Project Zomboid ${serverName} (${pack.description})"
        else
          "Project Zomboid server: ${name}";

      # Workshop ids from the pack and the server are concatenated (not
      # overridden) — a server ADDS mods to its pack rather than replacing it.
      workshopItems = map (m: m.id) (pack.workshopMods ++ srv.workshopMods);

      sandbox = lib.recursiveUpdate pack.defaultSandbox srv.sandbox;
    in
    {
      inherit
        serverName
        workshopItems
        settings
        description
        sandbox
        pinnedMap
        ;

      # Everything the systemd units, the web shim and the assertions read. This
      # list is the contract between the resolver and modules/*.nix: a field
      # added to an option but not here fails with "attribute X missing" deep in
      # services.nix rather than at the option.
      inherit (srv)
        adminAccount
        admins
        autoStart
        baseMap
        betaBranch
        clientHost
        compatibility
        defaultPort
        enable
        extraArgs
        extraServiceConfig
        hardware
        javaAgent
        jvmOpts
        localMods
        managementSystem
        mapOrder
        open
        openFirewall
        passwordFile
        port
        rconPort
        secretFiles
        selfManagedMods
        softReset
        spawn
        restart
        udpPort
        upnp
        webConsole
        whitelist
        ;

      # True when the resolved `Map=` must be computed from the installed mods
      # rather than taken from the configuration.
      autoMaps = pinnedMap == null;

      name = name;
      modpack = srv.modpack;
      packDescription = pack.description;

      # `Mods=` is a comma-separated list of local mod *folder* names (from each
      # mod's mod.info `id=` value), unlike WorkshopItems which are the ids above.
      #
      # `localMods` contributes its KEYS: the key is the mod folder name, and
      # naming it here is what makes declaring the directory its only mention —
      # otherwise a local mod would have to be listed twice and the two would
      # drift. Deduplicated so a pack that already lists the id does not get it
      # twice.
      mods = lib.unique (pack.mods ++ srv.mods ++ builtins.attrNames srv.localMods);
    };

  # `Key=value ...` argv for merge_ini.py. Secrets are deliberately NOT here:
  # they travel as `--secret-file Key=path` so the value never enters a unit file,
  # a store path or `ps` output. See pz.secretIniKeys.
  iniUpdates =
    resolved:
    renderIniLines {
      inherit (resolved)
        settings
        mods
        workshopItems
        whitelist
        admins
        ;
      legacyBuild41 = resolved.compatibility.build41;
    };

  # The effective Key -> path map of secrets. `passwordFile` is sugar for
  # `secretFiles.Password` and deliberately WINS over it, being the older and more
  # specific option.
  #
  # `--secret-file Key=path` argv for merge_ini.py. Note only the *path* is
  # interpolated, never a value — so nothing sensitive reaches a store path, a
  # unit file or `ps` output.
  secretFilesOf =
    resolved:
    resolved.secretFiles
    // lib.optionalAttrs (resolved.passwordFile != null) {
      Password = resolved.passwordFile;
    };

  secretFileArgs =
    resolved:
    concatMapStringsSep " \\\n        " (
      key: "--secret-file ${key}=${(secretFilesOf resolved).${key}}"
    ) (lib.attrNames (secretFilesOf resolved));

  # ── Reverse-proxy integration, without depending on anyone's proxy module ──
  # Returns `[{ name, port, path, stripPrefix, displayName; }]` for the
  # web-console servers. Consumers wire it into their own upstream option:
  #
  #   proxy.upstreams = lib.mkMerge (map mkUpstream
  #     (config.services.project-zomboid-servers.webConsoleUpstreams));
  mkProxyUpstreams =
    {
      webServers,
      webPort,
      pathPrefix ? "pz",
    }:
    map (name: {
      name = "pz-${name}";
      port = webPort name;
      path = "/${pathPrefix}/${name}/";
      stripPrefix = true;
      displayName = "Project Zomboid console: ${name}";
    }) (builtins.attrNames webServers);

in
{
  inherit
    renderIniValue
    renderLuaValue
    renderIniLines
    renderSandbox
    renderSpawnPoints
    renderSpawnRegions
    secretIniKeys
    secretFilesOf
    secretFileArgs
    iniUpdates
    resolveServer
    mkProxyUpstreams
    emptyPack
    ;

  # Both UDP ports one PZ instance needs.
  udpPortsOf = srv: [
    srv.defaultPort
    srv.udpPort
  ];
}
