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
  inherit (lib) concatStringsSep mapAttrsToList removeAttrs;

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
      whitelist,
      admins,
    }:
    let
      key = n: v: "${n}=${renderIniValue v}";
      # The keys the module owns, always written first and in this order.
      ordered = [
        (key "DefaultPort" settings.defaultPort)
        (key "UDPPort" settings.udpPort)
        (key "RCONPort" settings.rconPort)
        (key "Public" settings.public)
        (key "PublicName" settings.publicName)
        (key "MaxPlayers" settings.maxPlayers)
        (key "Open" settings.open)
        (key "Map" settings.map)
        (key "Mods" (concatStringsSep "," mods))
        (key "WorkshopItems" (concatStringsSep ";" workshopItems))
        (key "Whitelist" (concatStringsSep "," whitelist))
        (key "Users" (concatStringsSep "," admins))
      ];
      # Everything else the user passed through `settings`, which the module does
      # not own — rendered after, so ordering stays deterministic.
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
        "whitelist"
        "admins"
      ];
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

      # The `.ini` settings: pack defaults, then the module-owned keys, then the
      # server's own inline overrides.
      settings = lib.recursiveUpdate (
        pack.defaultSettings
        // {
          map = srv.map;
          defaultPort = srv.defaultPort;
          udpPort = srv.udpPort;
          rconPort = srv.rconPort;
          maxPlayers = srv.maxPlayers;
          public = if srv.public != null then srv.public else true;
          publicName = if srv.publicName != null then srv.publicName else name;
          open = if srv.open != null then srv.open else true;
        }
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
        ;
      # Everything the systemd units, the web shim and the assertions read. This
      # list is the contract between the resolver and modules/*.nix: a field
      # added to an option but not here fails with "attribute X missing" deep in
      # services.nix rather than at the option.
      inherit (srv)
        admins
        autoStart
        defaultPort
        enable
        extraServiceConfig
        hardware
        jvmOpts
        managementSystem
        map
        open
        openFirewall
        passwordFile
        port
        rconPort
        restart
        udpPort
        webConsole
        whitelist
        ;

      name = name;
      modpack = srv.modpack;
      packDescription = pack.description;

      # `Mods=` is a comma-separated list of local mod *folder* names (from each
      # mod's mod.info `id=` value), unlike WorkshopItems which are the ids above.
      mods = pack.mods ++ srv.mods;
    };

  # `Key=value ...` argv for merge_ini.py. The Password is passed out-of-band as
  # `@read@` so the secret never appears in a unit file or in `ps` output.
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
    }
    ++ lib.optional (resolved.passwordFile != null) "Password=@read@";

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
