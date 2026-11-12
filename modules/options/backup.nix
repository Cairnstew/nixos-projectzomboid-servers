# modules/options/backup.nix
#
# Scheduled world backups.
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
    # ── Backups ──────────────────────────────────────────────────────────────

    backup = {
      enable = mkEnableOption "scheduled world backups";

      directory = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/mnt/backup/project-zomboid";
        description = ''
          Root directory for archives. <literal>null</literal> uses
          <literal>''${dataDir}/backups</literal>. Each server gets a
          subdirectory named after it.

          The backup unit runs as the server user, so this path must be
          writable by <option>user</option>. Point it at another disk if the
          data disk is not where backups belong.
        '';
      };

      keep = mkOption {
        type = types.int;
        default = 7;
        description = ''
          Number of archives to keep per server. Older archives are deleted
          after a successful new one. <literal>0</literal> disables pruning
          (keep everything) — be careful on a small disk.
        '';
      };

      schedule = mkOption {
        type = types.str;
        default = "daily";
        example = "*-*-* 04:30:00";
        description = ''
          <literal>OnCalendar</literal> for the backup timer. The default runs
          once a day; systemd's calendar syntax accepts values such as
          <literal>hourly</literal>, <literal>*-*-* 04:30:00</literal>, or
          <literal>Mon..Fri 03:00</literal>.
        '';
      };

      randomDelaySec = mkOption {
        type = types.int;
        default = 1800;
        description = "Random delay added to the timer, so a fleet does not back up at the same instant.";
      };
    };
  };
}
