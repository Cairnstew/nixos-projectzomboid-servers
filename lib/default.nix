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

  # ── Keys that are NOT free-form in `settings` ───────────────────────────────
  # Each key below is either written by `renderIniLines` or owned by a dedicated
  # server option (`defaultPort`, `maxPlayers`, `upnp`, …). Accepting one through
  # `settings` would emit a SECOND line for the same key: merge_ini.py keeps the
  # last one, so the option and the file would silently disagree. `Map` is worse
  # still — the prep script always supplies a value at start, so `settings.Map`
  # would be overwritten every boot with no warning. Rejected by name, with the
  # option to use instead.
  reservedIniKeys = {
    DefaultPort = "defaultPort";
    UDPPort = "udpPort";
    RCONPort = "rconPort";
    Public = "public";
    PublicName = "publicName";
    MaxPlayers = "maxPlayers";
    Open = "open";
    Map = "map (or omit it for auto-detection)";
    Mods = "the modpack's `mods` / the server's `localMods`";
    WorkshopItems = "the modpack's `workshopMods` / the server's `workshopMods`";
    UPnP = "upnp";
    SelfManagedMods = "selfManagedMods";
    Whitelist = "whitelist (Build 41)";
    Users = "admins (Build 41)";
  };

  # Shared between `resolveServer` (the user's own settings) and
  # `renderIniLines` (pack defaults and direct callers).
  reservedKeyError =
    given:
    throw ''
      project-zomboid-servers: these keys have their own option and cannot be
      set through `settings`:

      ${concatStringsSep "\n" (map (k: "  - ${k}  →  set `${reservedIniKeys.${k}}`") given)}

      `settings` is for .ini keys the module does not otherwise own. Writing
      one of these here would either duplicate a rendered line (the last one
      wins in merge_ini.py, so the option and the file silently disagree) or
      be overwritten by the value supplied at start.
    '';

  # ── Build 41 keys that no longer mean anything in Build 42 ──────────────────
  # Project Zomboid IGNORES an unknown key silently — the server still starts,
  # the setting simply does nothing. That is the worst failure mode for a
  # declarative config, so these are rejected by name. The authority is the
  # running build's own generated file: 42.21 writes every key it reads into
  # `Zomboid/Server/<name>.ini` and `<name>_SandboxVars.lua`, including the
  # nested `ZombieLore`/`ZombieConfig` tables.
  #
  # Most entries moved section (`.ini` → SandboxVars) or were renamed; the rest
  # were removed outright. Only names verified against a generated 42.21 file
  # are listed, so a false positive cannot break a working config.
  staleIniKeys = {
    ConstructionPreventsLootRespawn = "sandbox.ConstructionPreventsLootRespawn";
    HoursForLootRespawn = "sandbox.HoursForLootRespawn";
    MaxItemsForLootRespawn = "sandbox.MaxItemsForLootRespawn";
    MinutesPerPage = "sandbox.MinutesPerPage";
    DisableSafehouseWhenPlayerConnected = "DisableSafehouseWhenOwnerConnected";
    DiscordChannel = "DiscordChatChannel (or DiscordLogChannel / DiscordCommandChannel)";
    DiscordChannelID = "DiscordChatChannel (a channel id is accepted there)";
    AllowTradeUI = "removed in Build 42";
    AutoCreateUserInWhiteList = "removed in Build 42 (the whitelist is a db table)";
    CoopMasterPingTimeout = "removed in Build 42";
    CoopServerLaunchTimeout = "removed in Build 42";
    KickFastPlayers = "removed in Build 42";
    LogLocalChat = "removed in Build 42";
    PhysicsDelay = "removed in Build 42";
    PingFrequency = "removed in Build 42 (PingLimit still exists)";
    PlayerSaveOnDamage = "removed in Build 42";
    SaveTransactionID = "removed in Build 42";
    SteamPort1 = "removed in Build 42";
    SteamPort2 = "removed in Build 42";
    UPnPForce = "removed in Build 42";
    UPnPLeaseTime = "removed in Build 42";
    UPnPZeroLeaseTimeFallback = "removed in Build 42";
    UseTCPForMapDownloads = "removed in Build 42";
    VoiceBuffering = "removed in Build 42";
    VoiceComplexity = "removed in Build 42";
    VoicePeriod = "removed in Build 42";
    VoiceSampleRate = "removed in Build 42";
    ZombieUpdateDelta = "removed in Build 42";
    ZombieUpdateMaxHighPriority = "removed in Build 42";
    ZombieUpdateRadiusHighPriority = "removed in Build 42";
    ZombieUpdateRadiusLowPriority = "removed in Build 42";
  };

  staleSandboxKeys = {
    # The B41 `*Loot` enums became `*LootNew` floats (0.00–4.00).
    AmmoLoot = "AmmoLootNew";
    CannedFoodLoot = "CannedFoodLootNew";
    FoodLoot = "FoodLootNew (a 0.00–4.00 multiplier, not a 1–5 enum)";
    LiteratureLoot = "LiteratureLootNew";
    MechanicsLoot = "MechanicsLootNew";
    MedicalLoot = "MedicalLootNew";
    OtherLoot = "OtherLootNew";
    RangedWeaponLoot = "RangedWeaponLootNew";
    SurvivalGearsLoot = "SurvivalGearsLootNew";
    WeaponLoot = "WeaponLootNew";
    # Split in B42.
    FuelStationGas = "FuelStationGasMin / FuelStationGasMax / FuelStationGasEmptyChance";
    LootRespawn = "HoursForLootRespawn / SeenHoursPreventLootRespawn / MaxItemsForLootRespawn";
    # Removed in B42.
    Decomp = "removed in Build 42";
    Smell = "removed in Build 42";
    XpMultiplier = "removed in Build 42";
    # Known-bad spellings that are not B41 keys either, but a plausible
    # misreading of the B42 list. Kept because they are silent no-ops.
    MeleeWeaponLootNew = "WeaponLootNew";
    ZombieDamage = "ZombieLore.Strength / ZombieLore.Toughness";
  };

  # ── SandboxVars keys that only work inside a nested table ───────────────────
  # Build 42 moved these into Lua tables and registers them under the DOTTED
  # name (`ZombieConfig.PopulationStartMultiplier`); a flat key is therefore an
  # unknown option and is ignored. `sandbox` accepts the dotted form:
  #
  #   sandbox."ZombieConfig.PopulationStartMultiplier" = 1.5;
  #
  # The lists come from the 42.21 server's own `SandboxOptions` classes and were
  # cross-checked against a generated `SandboxVars.lua`, which writes every
  # table and key the server reads. A short name may appear in more than one
  # table (`Strength` is both a MultiplierConfig skill and a ZombieLore
  # setting), so the guard reports every candidate.
  nestedSandboxTables = {
    Basement = [ "SpawnFrequency" ];
    Map = [
      "AllowMiniMap"
      "AllowWorldMap"
      "MapAllKnown"
      "MapNeedsLight"
    ];
    MultiplierConfig = [
      "Aiming"
      "Axe"
      "Blacksmith"
      "Blunt"
      "Butchering"
      "Carving"
      "Cooking"
      "Doctor"
      "Electricity"
      "Farming"
      "Fishing"
      "Fitness"
      "FlintKnapping"
      "Glassmaking"
      "Global"
      "GlobalToggle"
      "Husbandry"
      "Lightfoot"
      "LongBlade"
      "Maintenance"
      "Masonry"
      "Mechanics"
      "MetalWelding"
      "Nimble"
      "PlantScavenging"
      "Pottery"
      "Reloading"
      "SmallBlade"
      "SmallBlunt"
      "Sneak"
      "Spear"
      "Sprinting"
      "Strength"
      "Tailoring"
      "Tracking"
      "Trapping"
      "Woodwork"
    ];
    ZombieConfig = [
      "FollowSoundDistance"
      "PopulationMultiplier"
      "PopulationPeakDay"
      "PopulationPeakMultiplier"
      "PopulationStartMultiplier"
      "RallyGroupRadius"
      "RallyGroupSeparation"
      "RallyGroupSize"
      "RallyGroupSizeVariance"
      "RallyTravelDistance"
      "RedistributeHours"
      "RespawnHours"
      "RespawnMultiplier"
      "RespawnUnseenHours"
      "ZombiesCountBeforeDelete"
    ];
    ZombieLore = [
      "ActiveOnly"
      "ChanceOfAttachedWeapon"
      "Cognition"
      "CrawlUnderVehicle"
      "DisableFakeDead"
      "DoorOpeningPercentage"
      "FenceDamageMultiplier"
      "FenceThumpersRequired"
      "Hearing"
      "Memory"
      "Mortality"
      "PlayerSpawnZombieRemoval"
      "Reanimate"
      "Sight"
      "Speed"
      "SpottedLogic"
      "SprinterPercentage"
      "Strength"
      "ThumpNoChasing"
      "ThumpOnConstruction"
      "Toughness"
      "Transmission"
      "TriggerHouseAlarm"
      "ZombiesArmorFactor"
      "ZombiesCrawlersDragDown"
      "ZombiesDragDown"
      "ZombiesFallDamage"
      "ZombiesFenceLunge"
      "ZombiesMaxDefense"
    ];
  };

  nestedSandboxTablesOf =
    k: lib.filter (t: lib.elem k nestedSandboxTables.${t}) (builtins.attrNames nestedSandboxTables);

  # Short names that are ALSO valid flat keys, so a flat use must not be
  # rejected. `Farming` is the farming-speed enum at the top level and the
  # Farming skill multiplier inside MultiplierConfig.
  ambiguousFlatSandboxKeys = [ "Farming" ];

  staleKeyError =
    kind: table: given:
    throw ''
      project-zomboid-servers: these ${kind} keys are not valid in Build 42:

      ${concatStringsSep "\n" (map (k: "  - ${k}  →  ${table.${k}}") given)}

      Project Zomboid ignores an unknown key silently, so each of these would
      do nothing — including a server that starts cleanly. Check the key against
      the build's own generated file (`Zomboid/Server/<name>.ini` and
      `<name>_SandboxVars.lua`), which lists every key the server actually reads.
    '';

  # ── Value rendering ─────────────────────────────────────────────────────────
  # A `.ini` value. PZ's own ini writer emits bare values, so strings with inner
  # spaces are safe unquoted; booleans render as true/false.
  #
  # A line break is REJECTED rather than emitted. The `.ini` format has no escape
  # sequence: a raw newline ends the value, and the remainder is read back as a
  # line with no `=`, which merge_ini.py drops — so the setting would silently
  # truncate on the next start. PZ's own line-break syntax is the literal
  # `<LINE>` token (ServerWelcomeMessage, PublicDescription); the error says so.
  renderIniValue =
    v:
    if builtins.isBool v then
      (if v then "true" else "false")
    else
      let
        s = toString v;
      in
      if lib.hasInfix "\n" s || lib.hasInfix "\r" s then
        throw ''
          project-zomboid-servers: an .ini value cannot contain a line break
          (got ${builtins.toJSON s}).

          Project Zomboid has no escape sequence for a newline in the .ini. For
          the keys that support line breaks (ServerWelcomeMessage,
          PublicDescription) use the literal <LINE> token instead.
        ''
      else
        s;

  # A Lua string literal. Newlines are escaped to `\n`: Lua forbids a raw
  # newline inside a short (`"…"`) string, so leaving one in would make the
  # whole SandboxVars file a syntax error — and PZ would then regenerate it from
  # defaults, discarding every setting in the file.
  quoteLua =
    s: "\"${lib.replaceStrings [ "\\" "\"" "\n" "\r" "\t" ] [ "\\\\" "\\\"" "\\n" "\\r" "\\t" ] s}\"";

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
      staleGiven = filter (k: builtins.hasAttr k staleSandboxKeys) (builtins.attrNames settings);

      # A flat key that only exists inside a table is a silent no-op.
      nestedFlatGiven = filter (
        k: !(lib.hasInfix "." k) && !(lib.elem k ambiguousFlatSandboxKeys) && nestedSandboxTablesOf k != [ ]
      ) (builtins.attrNames settings);

      parts = k: lib.splitString "." k;
      dotted = lib.filterAttrs (k: _: lib.hasInfix "." k) settings;

      # The version header is NOT optional. PZ upgrades the VALUES of a file
      # older than the running build: a missing VERSION reads as 0, and
      # `upgradeOptionValue` then rewrites e.g. `DayLength = 8` (5 hours in B42)
      # to the B41-era index 14 (11 hours). 42.21 writes `VERSION = 6`, and so
      # must this renderer. A caller may override it for an older build.
      version = if settings ? VERSION then settings.VERSION else 6;
      top = removeAttrs (lib.filterAttrs (k: _: !(lib.hasInfix "." k)) settings) [ "VERSION" ];

      dottedProblem = filter (
        k:
        let
          p = parts k;
          table = builtins.head p;
        in
        builtins.length p != 2
        || !(builtins.hasAttr table nestedSandboxTables)
        || !(lib.elem (builtins.elemAt p 1) nestedSandboxTables.${table})
      ) (builtins.attrNames dotted);

      grouped = lib.groupBy (k: builtins.head (parts k)) (builtins.attrNames dotted);

      renderFlat = n: v: "    ${n} = ${renderLuaValue v}";
      renderTable =
        table: keys:
        "    ${table} = {\n"
        + concatStringsSep ",\n" (
          map (k: "        ${builtins.elemAt (parts k) 1} = ${renderLuaValue dotted.${k}}") keys
        )
        + "\n    }";

      entries = [
        "    VERSION = ${toString version}"
      ]
      ++ mapAttrsToList renderFlat top
      ++ lib.mapAttrsToList renderTable grouped;
      body = concatStringsSep ",\n" entries;
    in
    if staleGiven != [ ] then
      staleKeyError "SandboxVars" staleSandboxKeys staleGiven
    else if nestedFlatGiven != [ ] then
      throw ''
        project-zomboid-servers: these SandboxVars keys only exist inside a
        nested table in Build 42. A flat key is an unknown option and is ignored
        silently — use the dotted form instead:

        ${concatStringsSep "\n" (
          map (
            k:
            "  - sandbox.${k}  →  ${
                concatStringsSep " / " (map (t: "sandbox.\"${t}.${k}\"") (nestedSandboxTablesOf k))
              }"
          ) nestedFlatGiven
        )}
      ''
    else if dottedProblem != [ ] then
      throw ''
        project-zomboid-servers: invalid nested SandboxVars key(s):

        ${concatStringsSep "\n" (map (k: "  - ${k}") dottedProblem)}

        Use `Table.Key`, where Table is one of:
        ${concatStringsSep ", " (builtins.attrNames nestedSandboxTables)}.
      ''
    else if !(builtins.isInt version) then
      throw ''
        project-zomboid-servers: sandbox.VERSION must be an integer (got
        ${builtins.toJSON version}). Leave it unset — the renderer writes the
        current build's version.
      ''
    else
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
        # Rendered directly below, because a dedicated option owns them but they
        # are stored in `settings` under their ini spelling.
        "UPnP"
        "SelfManagedMods"
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
      ++ lib.optional (settings ? UPnP) (key "UPnP" settings.UPnP)
      # Build 41 only. `SelfManagedMods` is absent from the 42.21 game jar (it
      # contains every key it reads, including the client classes) and from the
      # 144-key `.ini` the server writes back, so Build 42 never reads it — it
      # is exactly the silent no-op these guards exist to reject. Build 41 does
      # honour it, so it stays behind the same switch as `Whitelist`/`Users`.
      ++ lib.optional (legacyBuild41 && settings ? SelfManagedMods) (
        key "SelfManagedMods" settings.SelfManagedMods
      )
      ++ lib.optional (settings ? map) (key "Map" settings.map)
      ++ [
        (key "Mods" (concatStringsSep ";" mods))
        (key "WorkshopItems" (concatStringsSep ";" workshopItems))
      ]
      ++ lib.optional legacyBuild41 (key "Whitelist" (concatStringsSep "," whitelist))
      ++ lib.optional legacyBuild41 (key "Users" (concatStringsSep "," admins));

      # Everything left is a genuine free-form key. A reserved one is a mistake:
      # fail with the option that owns it rather than render a duplicate.
      extras = removeAttrs settings owned;
      reservedGiven = filter (k: builtins.hasAttr k reservedIniKeys) (builtins.attrNames extras);
      staleGiven = filter (k: builtins.hasAttr k staleIniKeys) (builtins.attrNames extras);
    in
    if reservedGiven != [ ] then
      reservedKeyError reservedGiven
    else if staleGiven != [ ] then
      staleKeyError "settings" staleIniKeys staleGiven
    else
      ordered ++ mapAttrsToList key extras;

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

      # A reserved key in the user's own `settings` would be masked by the value
      # written here (or, for `Map`, by the value the prep script supplies at
      # start), so reject it while resolving rather than let it disappear. The
      # renderer checks pack defaults and direct callers; this catches the
      # resolver-inserted keys, which `settings` can otherwise override.
      reservedGiven = filter (k: builtins.hasAttr k reservedIniKeys) (builtins.attrNames srv.settings);

      # The `.ini` settings: pack defaults, then the module-owned keys, then the
      # server's own inline overrides.
      settings =
        if reservedGiven != [ ] then
          reservedKeyError reservedGiven
        else
          lib.recursiveUpdate (
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

      # PZ starts RCON only when the port is non-zero AND the password is
      # non-empty — `GameServer`:
      #   if (port != 0 && password != null && !password.isEmpty()) RCONServer.init(...)
      # A port with no password therefore looks configured and does nothing, so
      # it is reported at evaluation time instead of being left as a silent
      # no-op. `RCONPassword` cannot come from `settings` (it is a secret key),
      # so `secretFiles` is the only place to look.
      warnings =
        lib.optional (srv.rconPort != 0 && !(srv.secretFiles ? RCONPassword)) ''
          services.project-zomboid-servers.servers."${name}": rconPort is ${toString srv.rconPort}
          but no RCONPassword secret is configured. Project Zomboid starts RCON only
          when the port is non-zero AND the password is non-empty, so RCON will
          silently stay off. Set `secretFiles.RCONPassword = …;` (or `rconPort = 0;`).
        ''
        # 42.21 ships no UPnP implementation: the jar contains no UPnP class at
        # all, and `ServerOptions.uPnp` is never read by `GameServer`. `UPnP=` is
        # still a live ini key (the game writes it back), so nothing else rejects
        # it — which is exactly the silent no-op this warning exists to surface.
        ++ lib.optional (srv.upnp && !srv.compatibility.build41) ''
          services.project-zomboid-servers.servers."${name}": upnp is enabled, but Build 42
          has no UPnP implementation (the 42.21 jar contains no UPnP classes and
          `ServerOptions.uPnp` is never read), so `UPnP=` does nothing and the router
          will not forward defaultPort/udpPort. Forward them on the router yourself —
          or map them with a UPnP client such as miniupnpc — and drop `upnp`.
        '';
    in
    {
      inherit
        serverName
        workshopItems
        settings
        description
        sandbox
        pinnedMap
        warnings
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
        openRconFirewall
        passwordFile
        port
        rconPort
        secretFiles
        selfManagedMods
        softReset
        spawn
        restart
        schedule
        idleStop
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

      # `Mods=` is a semicolon-separated list of local mod *folder* names (from
      # each mod's mod.info `id=` value), like WorkshopItems above.
      #
      # NOT commas. Build 42 splits `Mods=` on `;` only (the game's own
      # ServerSettingsScreen joins and splits with ";"), so a comma-joined list
      # is read as ONE mod id: the server logs `required mod "<whole list>" not
      # found`, loads no mods, and every `Map=` entry is then "non-existent".
      # Build 41 also uses semicolons — do not "restore" commas.
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

  # Deterministic web-console port assignment. Shared by modules/config.nix
  # (the advertised proxy upstreams) and modules/services.nix (the ttyd
  # listener), so the two can never disagree about which port a server uses.
  #
  # Ports are assigned in sorted server order and only among servers that asked
  # for a console, so renaming a server can move the ports of later ones but
  # adding a server cannot renumber an earlier one.
  mkWebPort =
    {
      portBase,
      resolved,
      webServers,
    }:
    name:
    if resolved.${name}.port != null then
      resolved.${name}.port
    else
      portBase + (lib.length (builtins.filter (n: n < name) (builtins.attrNames webServers)));

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
    reservedIniKeys
    staleIniKeys
    staleSandboxKeys
    nestedSandboxTables
    secretIniKeys
    secretFilesOf
    secretFileArgs
    iniUpdates
    resolveServer
    mkWebPort
    mkProxyUpstreams
    emptyPack
    ;

  # Both UDP ports one PZ instance needs.
  udpPortsOf = srv: [
    srv.defaultPort
    srv.udpPort
  ];
}
