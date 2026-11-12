# modules/services.nix
#
# The systemd units: the shared install/update, one service (+ console socket)
# per server, and optional ttyd web consoles.
#
# Design notes that are easy to get wrong and are therefore load-bearing here:
#
#   * `ExecStart`/`ExecStop`/`ExecStartPre` are ALWAYS a store path from
#     `pkgs.writeShellApplication` + `lib.getExe`. systemd requires an absolute
#     path as the first token of an Exec line, so a bare multi-line shell string
#     (which an earlier draft of this module used for ExecStartPre) fails
#     203/EXEC. writeShellApplication also brings `set -euo pipefail` and a
#     shellcheck pass at build time.
#
#   * `Requires=`/`After=` only ever name units that THIS module defines. A
#     reference to a non-existent unit makes `systemctl start` fail outright, so
#     the install unit below lives in the same file as the servers that require
#     it.
#
#   * Nothing interpolates a multi-line string into the middle of a Nix `''`
#     block. Nix strips the *minimum* indentation of a multiline string, so an
#     interpolated value carrying its own newlines silently de-indents the rest
#     of the block and breaks any heredoc terminator. Multi-line content is
#     therefore rendered to a store file with `pkgs.writeText` and `cp`'d, and
#     every argv value is shell-escaped and passed on a single line.

# The unit builders live in `services/` by concern. This file is the single
# import point; each concern imports `services/context.nix` for the shared
# resolution of servers, ports and paths.
{ ... }:

{
  imports = [
    ./services/client-host.nix
    ./services/install.nix
    ./services/server.nix
    ./services/web.nix
  ];
}
