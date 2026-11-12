# modules/options/core.nix
#
# Global options: the package and its directories, the shared Steam install,
# update policy, and the crash-loop limits.
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
  inherit (import ./types.nix { inherit lib; }) settings workshopMod;
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

    workshopDir = mkOption {
      type = types.path;
      default = "${config.services.project-zomboid-servers.serverDir}/steamapps/workshop/content/108600";
      defaultText = literalExpression ''
        "''${services.project-zomboid-servers.serverDir}/steamapps/workshop/content/108600"
      '';
      example = "/mnt/data/project-zomboid/server/steamapps/workshop/content/108600";
      description = ''
        Where the <emphasis>dedicated</emphasis> server keeps its Steam Workshop
        content. Defaults under <option>serverDir</option>; set it explicitly so
        the dedicated half never depends on a path being derivable, and so it can
        live in a Steam library the client also uses (or not).

        Must be absolute and must end in
        <literal>/steamapps/workshop/content/108600</literal>: SteamCMD installs
        Workshop content relative to a library root, and the module derives that
        root from this path. Evaluation fails otherwise rather than downloading
        somewhere unexpected.

        This is <emphasis>only</emphasis> the dedicated-server copy. A client
        host never reads it, and the module never downloads into a client's Steam
        library — see <option>servers.&lt;name&gt;.clientHost</option>.
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

    steamLogin = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "seanc";
      description = ''
        Steam account name the shared install's steamcmd downloads authenticate
        as, instead of <literal>anonymous</literal>.

        <emphasis>This is the workaround for Workshop items anonymous cannot
        fetch.</emphasis> An item gated behind Steam's mature-content check, or
        restricted by its author, answers <literal>Access Denied</literal> to
        <literal>+login anonymous</literal> — Brita's Armor Pack is the known
        example. An account that <emphasis>owns Project Zomboid</emphasis> and
        has mature content enabled can download them.

        The password is never stored. SteamCMD caches a login token under
        <envar>HOME</envar>, and the install runs with
        <literal>HOME=&lt;dataDir&gt;</literal>, so log in once as that user:

        <programlisting>
        sudo -u project-zomboid env HOME=/var/lib/project-zomboid \
          steamcmd +login &lt;account&gt;
        </programlisting>

        That single interactive command answers the password and Steam Guard
        prompts; every later non-interactive run reuses the token. A systemd unit
        has no terminal, so a missing or expired token simply fails the install —
        which is loud and lists exactly which items could not be fetched, rather
        than starting a server with mods missing.

        If an item still cannot be fetched (its author disabled downloads
        entirely), supply it by hand through
        <option>servers.&lt;name&gt;.localMods</option>.
      '';
    };

    prune = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Make the installed mod set match what is declared — remove Workshop
        content that no enabled dedicated server asks for any more.

        Off by default because it <emphasis>deletes</emphasis> from the shared
        install, which every server on that install reads — the same reason
        <option>mapOrder.dedupe</option> is off. Turn it on for a clean pack
        switch:

        <itemizedlist>
          <listitem>
            <para>
              <option>workshopDir</option> is pruned to the union of every
              enabled server's <option>workshopItems</option>; and
            </para>
          </listitem>
          <listitem>
            <para>
              each server's <literal>Zomboid/Workshop/content/&lt;appid&gt;</literal>
              link farm is pruned to that server's own list, and its
              <literal>Zomboid/mods</literal> farm to its
              <option>localMods</option>.
            </para>
          </listitem>
        </itemizedlist>

        This matters beyond disk space: <literal>Map=</literal> is derived by
        scanning the shared workshop root, so a map shipped by a mod you removed
        would otherwise keep contributing terrain. Pruning happens only after
        every declared item has verified as present, so a failing download never
        triggers a delete.

        Local mods are only ever unlinked when they are symlinks this module
        made; a directory placed by hand is never touched.
      '';
    };

    failOnMissingMods = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Refuse to finish the install when a Workshop item cannot be downloaded
        (the default), versus logging the item, skipping it, and letting the
        servers boot anyway.

        True is the "never run modless" behaviour: the servers
        <literal>Require</literal> the install unit, so an unreachable item — a
        gated one steamcmd cannot authenticate for, a deleted one, a typo'd id —
        stops the boot and the failure lists every item.

        Set to <literal>false</literal> for a degraded-but-up server: the
        missing item is logged with the reason, the skipped count is printed,
        and the servers start without it. The item stays in
        <literal>WorkshopItems=</literal>, so PZ itself warns at start, and it
        is picked up by a later install the moment the content becomes
        fetchable — nothing needs to be re-declared. Prune is still withheld
        while anything is missing, so a later re-login can fetch what was
        skipped rather than find it deleted.
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
  };
}
