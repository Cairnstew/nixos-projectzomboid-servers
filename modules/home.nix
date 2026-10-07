# modules/home.nix
#
# The HOME side of the module — the in-game Host button's config lives in
# `~/Zomboid/Server/<name>.ini`, a user-level path no system module may own.
# The NixOS side therefore only RENDERS (`clientHosts.<name>.prepare`); this
# module RUNS it. It exists so that enabling the client host is enough: nobody
# has to hand-write a `home.activation` hook, and no host file has to hard-code
# where Steam put its library.
#
# The pack is read back from `osConfig`, so the mod list, the SandboxVars and
# the client-side server name are still described exactly ONCE, on the NixOS
# side, and cannot drift from what the dedicated server would have used.
#
# Standalone Home Manager (no NixOS system around it) has no `osConfig`, so this
# module is inert there rather than an error.
{
  config,
  lib,
  options,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    types
    literalExpression
    concatStringsSep
    mapAttrsToList
    optionalString
    ;

  cfg = config.services.project-zomboid-servers;

  osCfg =
    if options ? osConfig then (config.osConfig.services.project-zomboid-servers or null) else null;

  hosts = if osCfg == null then { } else osCfg.clientHosts;
in
{
  options.services.project-zomboid-servers.home = {
    enable = mkOption {
      type = types.bool;
      default = hosts != { };
      defaultText = literalExpression "osConfig.services.project-zomboid-servers.clientHosts != { }";
      description = ''
        Seed the client's Project Zomboid home from the pack, so the game's
        in-game <emphasis>Host</emphasis> button offers the world with its mod
        list and SandboxVars already filled in — the same files a dedicated
        server would have run.

        Defaults to on exactly when the NixOS side has
        <option>clientHosts</option>, so importing this module is all it takes;
        set it explicitly only to force the behaviour off (or on, in a Home
        Manager that has no <literal>osConfig</literal>).
      '';
    };

    linkSteamWorkshop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Symlink the shared SteamCMD download into the client's Steam library, so
        the same Workshop items are not downloaded twice.

        <warning>
          <para>
            This does <emphasis>not</emphasis> make the mods load in the game
            client: Project Zomboid's client enumerates Workshop mods through
            Steam's subscription list and never scans the library, so symlinked
            content is invisible to it. It is parity with the dedicated server
            plus a saved download; a hosted world still needs the items
            subscribed in Steam for the client to load them. See
            <filename>GOTCHAS.md</filename> in the consumer's repo.
          </para>
        </warning>
      '';
    };
  };

  config = mkIf (cfg.home.enable && hosts != { }) {
    home.activation.project-zomboid-client-host = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      concatStringsSep "\n" (
        mapAttrsToList (_name: host: ''
          (
            export PZ_CLIENT_ZOMBOID="$HOME/Zomboid"
            export PZ_SERVER_DIR="${osCfg.serverDir}"
            ${optionalString (!cfg.home.linkSteamWorkshop) "export PZ_LINK_STEAM_WORKSHOP=0"}
            run ${lib.getExe host.prepare}
          )
        '') hosts
      )
    );
  };
}
