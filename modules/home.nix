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
# It also owns getting the MODS onto the machine (`home.installMods`). That is
# deliberately here and not on the NixOS side: it writes into the user's
# `~/Zomboid/mods` and Steam area. Note it INSTALLS LOCAL MODS rather than
# subscribing — Steam subscriptions are not scriptable (no public API, no
# `steamcmd` command, no local file), so a client that loads a pack without
# clicking Subscribe in Steam does it as local mods.
#
# Standalone Home Manager (no NixOS system around it) has no `osConfig`, so this
# module is inert there rather than an error.
{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:
let
  inherit (lib)
    mkIf
    mkMerge
    mkOption
    types
    literalExpression
    concatStringsSep
    mapAttrsToList
    optionalString
    ;

  cfg = config.services.project-zomboid-servers;

  # `osConfig` is a module ARGUMENT, not an option: Home Manager's NixOS
  # integration passes it through `specialArgs`, and a standalone Home Manager
  # leaves it at the `_module.args` default of null
  # (modules/misc/submodule-support.nix).
  #
  # Reading it as `options ? osConfig` is the trap, and it fails SILENTLY: there
  # is no option by that name, so the test is always false, the module does
  # nothing, and it still looks correctly wired up.
  osCfg = if osConfig == null then null else (osConfig.services.project-zomboid-servers or null);

  hosts = if osCfg == null then { } else osCfg.clientHosts;

  # The client mod fetch, shared with the `pz-client-mods` flake app so the two
  # cannot drift. Built from the CONSUMER's pkgs, so this module needs no overlay.
  # Lazy: only forced when `installMods` is on.
  clientMods = pkgs.callPackage ../pkgs/project-zomboid-client-mods { };

  # Every Workshop item ANY client host needs, de-duplicated at eval time: two
  # worlds may share a pack, and the same item must not be fetched twice.
  workshopIds = lib.unique (lib.concatMap (h: h.workshopItems) (lib.attrValues hosts));
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
            plus a saved download. To make the client actually load a pack
            without subscribing, use <option>installMods</option>. See
            <filename>GOTCHAS.md</filename> in the consumer's repo.
          </para>
        </warning>
      '';
    };

    installMods = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Fetch the pack's Workshop items and install them as <emphasis>local
        mods</emphasis> in <filename>~/Zomboid/mods</filename> — the form
        Project Zomboid's client loads with no Steam subscription.

        Steam subscriptions cannot be scripted: there is no public API, no
        <command>steamcmd</command> command, and no local file that encodes one
        (verified — the client's <filename>appworkshop_&lt;appid&gt;.acf</filename>
        has no <literal>subscribed</literal> flag). Installing the mods locally is
        the supported way to make a client load a pack it is not subscribed to.

        A systemd user service does the fetch. It is <emphasis>idempotent</emphasis>
        — an already-installed mod is skipped — so re-running is cheap, and it is
        a service rather than an activation because it downloads over the network,
        which must not block <command>home-manager switch</command>.

        Anonymous <command>steamcmd</command> cannot fetch every item; set
        <option>steamLogin</option> for those. A pack's non-Workshop
        <option>mods</option> cannot be downloaded at all and are reported for
        manual placement.
      '';
    };

    steamLogin = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "my_steam_account";
      description = ''
        Steam account to log in as when fetching mods — needed for items that
        answer <literal>Access Denied</literal> / <literal>File Not Found</literal>
        anonymously.

        The password is <emphasis>never</emphasis> stored: SteamCMD must have
        logged in once already
        (<command>steamcmd +login <replaceable>account</replaceable></command>),
        which caches a token under <envar>HOME</envar> that later non-interactive
        runs reuse. A systemd unit has no terminal, so it cannot answer a password
        prompt — an unauthenticated run simply fails and is visible in
        <command>journalctl --user -u project-zomboid-client-mods</command>.
      '';
    };
  };

  config = mkMerge [
    # ── The world config, installed on every switch ─────────────────────────
    (mkIf (cfg.home.enable && hosts != { }) {
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
    })

    # ── The mods themselves, fetched once at login ──────────────────────────
    (mkIf (cfg.home.installMods && hosts != { }) {
      systemd.user.services.project-zomboid-client-mods = {
        Unit = {
          Description = "Fetch the Project Zomboid pack's Workshop mods as local mods";
        };
        Service = {
          Type = "oneshot";
          # Not a lock: "active" means the last run finished. An installed mod is
          # skipped, so a repeat is a fast no-op rather than a re-download.
          RemainAfterExit = true;
          ExecStart = lib.getExe (
            pkgs.writeShellApplication {
              name = "project-zomboid-client-mods";
              runtimeInputs = [ clientMods ];
              text = ''
                exec ${lib.getExe clientMods} \
                  --ids ${lib.escapeShellArg (concatStringsSep "," workshopIds)} \
                  --zomboid "$HOME/Zomboid" \
                  ${optionalString (
                    cfg.home.steamLogin != null
                  ) "--login ${lib.escapeShellArg cfg.home.steamLogin}"}
              '';
            }
          );
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
