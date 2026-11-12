# modules/options/client-hosts.nix
#
# The rendered client-host handover (`clientHosts`).
{ lib, ... }:

let
  inherit (lib)
    mkOption
    types
    ;
in
{
  options.services.project-zomboid-servers = {
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
                A runnable script that writes the client's Project Zomboid config
                from this server's config. It is <emphasis>config only</emphasis>
                and takes a single environment variable:

                <programlisting>
                PZ_CLIENT_ZOMBOID=~/Zomboid \
                  /nix/store/…-project-zomboid-&lt;name&gt;-client-host
                </programlisting>

                It writes only
                <literal>$PZ_CLIENT_ZOMBOID/Server/&lt;name&gt;.ini</literal> and
                <literal>…/&lt;name&gt;_SandboxVars.lua</literal>, plus — when
                <option>servers.&lt;name&gt;.clientHost.preset.enable</option> is
                set — one merged preset line in
                <literal>…/Lua/pz_modlist_settings.cfg</literal>. It never runs
                SteamCMD, never references a Steam library, never touches
                <literal>~/.local/share/Steam</literal> and never writes
                <literal>~/Zomboid/mods</literal>.

                With <literal>WorkshopItems=</literal> populated, the game's Host
                button downloads the items through Steam into whichever library
                owns the PZ install. That is the whole client-side mod flow; see
                <filename>docs/mod-delivery.md</filename>.
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
            presetName = mkOption {
              type = types.nullOr types.str;
              description = ''
                Effective preset name, or <literal>null</literal> when
                <option>servers.&lt;name&gt;.clientHost.preset.enable</option> is
                off.
              '';
            };
            presetFile = mkOption {
              type = types.nullOr types.path;
              description = ''
                The Nix-rendered single-line preset fragment
                (<literal>&lt;name&gt;:id;id;…;</literal>), or
                <literal>null</literal> when the preset is off. Normally handed
                to <option>prepare</option>, which merges it into
                <literal>~/Zomboid/Lua/pz_modlist_settings.cfg</literal>.
              '';
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

        <emphasis>This renders without <option>enable</option>.</emphasis> A
        client host is a config target, not a dedicated server: with the master
        switch off, a configuration that only sets
        <literal>servers.&lt;name&gt;.clientHost.enable = true</literal> creates
        no install unit, no server user and no SteamCMD invocation. The mods
        themselves arrive through Steam when the Host button starts the world.
      '';
    };
  };
}
