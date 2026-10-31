# pkgs/project-zomboid-client-mods/default.nix
#
# The CLIENT-side mod fetch, packaged so the `pz-client-mods` flake app and the
# Home Manager module run the SAME script rather than two copies of the wrapper.
#
# The work is `scripts/pz_client_mods.py`; this pins its interpreter and command
# dependencies (python3, steamcmd). It no longer reads a Steam library at all:
# the only target is a local-mods directory, and steamcmd runs with an isolated
# HOME so it cannot touch the user's `libraryfolders.vdf`.
{
  lib,
  python3,
  steamcmd,
  coreutils,
  writeShellApplication,
}:
writeShellApplication {
  name = "pz-client-mods";
  runtimeInputs = [
    python3
    steamcmd
    coreutils
  ];
  text = ''
    exec python3 ${../../scripts/pz_client_mods.py} "$@"
  '';
  meta = {
    description = "Fetch a Project Zomboid modpack's Steam Workshop mods onto a client";
    longDescription = ''
      Downloads a pack's Workshop items with steamcmd and installs the mod(s)
      each contains as local mods in the client's Zomboid home — the form
      Project Zomboid's client loads without a Steam subscription. See
      `pz-client-mods --help`.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "pz-client-mods";
  };
}
