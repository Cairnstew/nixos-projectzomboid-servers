# modules/services/context.nix
#
# The values every unit builder shares. This is a plain function, not a module:
# each concern file imports it once and takes what it needs, so the resolution
# of servers, ports and paths is still written in exactly one place.
{
  config,
  lib,
  pkgs,
}:

let
  inherit (lib)
    concatMap
    optionals
    ;

  cfg = config.services.project-zomboid-servers;
  pz = import ../../lib { inherit lib; };
  prepare = import ../../lib/prepare.nix {
    inherit lib pkgs pz;
  };

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg.servers;

  # Evaluation-time warning, not an error: a misconfigured server still starts,
  # it just never opens its RCON listener. The condition lives in
  # `resolveServer` (`warnings`), so every consumer sees the same text.
  warnOnResolved =
    r: if r.warnings == [ ] then r else lib.warn (lib.concatStringsSep "\n\n" r.warnings) r;

  resolved = lib.mapAttrs (
    name: srv: warnOnResolved (pz.resolveServer cfg.modpacks name srv)
  ) enabledServers;
  serverNames = builtins.attrNames resolved;

  # Servers that asked for client-host files, resolved INDEPENDENTLY of `enable`.
  # That independence is the whole point: the main use of a client host is the
  # case where NO dedicated server exists on this host, and the pack must still
  # render. Deriving this from `resolved` would silently drop exactly that
  # configuration — a pack that renders nothing, with no error.
  clientResolved = lib.mapAttrs (
    name: srv:
    # Reuse `resolved` when the same server is also enabled, so one
    # misconfiguration is never reported twice.
    if builtins.hasAttr name resolved then
      resolved.${name}
    else
      warnOnResolved (pz.resolveServer cfg.modpacks name srv)
  ) (lib.filterAttrs (_: srv: srv.clientHost.enable) cfg.servers);

  # Every UDP port this module opens, in ONE place: enabled servers that asked
  # for their own ports, plus client hosts that asked for theirs. The client-host
  # half cannot come from `resolved` — that is filtered to `enable = true`, and
  # the usual client-host setup has no enabled server at all.
  firewallUdpPorts =
    concatMap (srv: optionals srv.openFirewall (pz.udpPortsOf srv)) (lib.attrValues resolved)
    ++ concatMap (srv: optionals srv.clientHost.openFirewall (pz.udpPortsOf srv)) (
      lib.attrValues clientResolved
    );

  unitName = pz.unitName;
  installUnit = unitName "install";

  consoleFifo = name: "${cfg.runDir}/${name}.fifo";
  webServers = lib.filterAttrs (_: srv: cfg.web.enable && srv.webConsole) resolved;

  # One implementation, shared with config.nix's advertised upstreams.
  webPort = pz.mkWebPort {
    inherit (cfg.web) portBase;
    inherit resolved webServers;
  };
in
{
  inherit
    cfg
    pz
    prepare
    enabledServers
    resolved
    serverNames
    clientResolved
    firewallUdpPorts
    unitName
    installUnit
    consoleFifo
    webServers
    webPort
    ;
}
