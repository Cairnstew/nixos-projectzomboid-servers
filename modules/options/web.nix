# modules/options/web.nix
#
# ttyd consoles and the read-only proxy-upstream list.
{ lib, ... }:

let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.services.project-zomboid-servers = {
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
          User the consoles run as. Added to the server group and granted a
          scoped polkit rule for <literal>org.freedesktop.systemd1.manage-units</literal>
          on the <literal>project-zomboid-*</literal> units only. This is polkit,
          not sudoers: a scoped sudo rule is unreachable on hosts that set
          <literal>security.sudo.execWheelOnly</literal>, while polkit grants
          exactly that one action on exactly those units.
        '';
      };

      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          HTTP basic-auth username. Requires <option>passwordFile</option>.

          The credential is passed to ttyd with <literal>--credential</literal>,
          so the password is visible in the process list
          (<filename>/proc/&lt;pid&gt;/cmdline</filename>) even though it never
          reaches the store or the unit file. Prefer authentication at the
          reverse proxy when that disclosure matters, and leave both options
          unset there.
        '';
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File holding the HTTP basic-auth password (e.g. an agenix secret).";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open the console ports.

          Off by default: the consoles are meant to sit behind an authenticating
          proxy or a private network. If <option>username</option> and
          <option>passwordFile</option> are unset, the consoles have no
          authentication of their own.
        '';
      };
    };
  };
}
