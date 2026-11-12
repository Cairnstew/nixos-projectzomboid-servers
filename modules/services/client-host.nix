# modules/services/client-host.nix
#
# The `~/Zomboid` handover. Deliberately outside the `enable`/`package` gate:
# a client host must render even when no dedicated server exists on the host.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  ctx = import ./context.nix { inherit config lib pkgs; };
  inherit (ctx)
    clientResolved
    prepare
    unitName
    firewallUdpPorts
    ;
in
{
  config = {
    services.project-zomboid-servers.clientHosts = lib.mapAttrs (
      name: srv:
      let
        clientName = srv.clientHost.name;
        iniBase = prepare.mkIniBase {
          server = srv;
          name = "${clientName}.ini";
        };
        # The preset is opt-in. Empty `preset.name` falls back to the server
        # attribute (`viewpoint`) so a client gets a recognisable entry without
        # having to name it twice.
        presetName =
          if srv.clientHost.preset.enable then
            (if srv.clientHost.preset.name != "" then srv.clientHost.preset.name else name)
          else
            null;
        presetFile =
          if presetName == null then
            null
          else
            prepare.mkModlistPreset {
              inherit (srv) mods;
              name = presetName;
            };
      in
      {
        inherit (srv) mods workshopItems;
        inherit presetName presetFile;
        serverName = clientName;
        iniFile = iniBase;
        sandboxFile = prepare.mkSandboxFile {
          server = srv;
          name = "${clientName}_SandboxVars.lua";
        };
        prepare = prepare.mkClientHostScript {
          name = "${unitName name}-client-host";
          server = srv;
          inherit
            iniBase
            clientName
            presetName
            presetFile
            ;
        };
      }
    ) clientResolved;

    # Declared HERE, outside the `enable` gate, because a client host's ports
    # must open even when no dedicated server exists.
    networking.firewall.allowedUDPPorts = firewallUdpPorts;
  };
}
