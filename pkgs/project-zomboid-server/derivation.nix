# pkgs/project-zomboid-server/derivation.nix
#
# Installs the launcher wrapper for an already-installed Project Zomboid
# dedicated server.
#
# This package does NOT contain the game — it wraps an install produced by
# steamcmd (`+app_update 380870 validate`), which lives on mutable disk in
# `serverDir` rather than in the store. See versions.json for why the depots are
# not pinned here yet.
#
# The wrapper itself is built by `writeShellApplication` (passed in as `launcher`)
# so it gets `set -euo pipefail`, the runtime shell and a shellcheck pass at
# build time; this file only lays it out in `$out` and records the metadata.
{
  lib,
  stdenvNoCC,
  launcher,
  steamAppId,
  serverAppId,
  version ? "unversioned",
}:

stdenvNoCC.mkDerivation {
  pname = "project-zomboid-server";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    ln -s ${launcher}/bin/project-zomboid-server "$out/bin/project-zomboid-server"
    runHook postInstall
  '';

  passthru = {
    inherit steamAppId serverAppId;
  };

  meta = {
    description = "Launcher wrapper for a steamcmd-installed Project Zomboid dedicated server";
    longDescription = ''
      Wraps an existing Project Zomboid dedicated server install (Steam app
      ${serverAppId}) so the join/steam app id and the JVM heap flags are right
      without editing the vendor's start-server.sh. The game itself is not
      included: point PZ_SERVER_DIR at a steamcmd-populated directory.

      The wrapper guarantees steam_appid.txt holds exactly one line
      (${steamAppId}) — a stale multi-id file makes Build 42 abort with
      "Assertion Failed: Illegal termination of worker thread" — and injects the
      -Xmx/-Xms flags that the Project Zomboid wiki requires you to edit by hand.
    '';
    homepage = "https://projectzomboid.com";
    license = lib.licenses.unfree;
    platforms = lib.platforms.unix;
    mainProgram = "project-zomboid-server";
  };
}
