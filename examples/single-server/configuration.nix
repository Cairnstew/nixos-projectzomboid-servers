# examples/single-server/configuration.nix
#
# A complete, minimal Project Zomboid server.
#
# Takes the flake as a module argument rather than closing over it, so the same
# file can be imported by a `nixosSystem` (see flake.nix) or by this project's
# own `lib.tests.eval` (see the example's check).
{
  project-zomboid-servers,
  ...
}:
{
  imports = [ project-zomboid-servers.nixosModules.project-zomboid-servers ];

  # ── Just enough host to make this a real NixOS system ──────────────────────
  # An example still has to answer NixOS's boot assertions, or `nix flake check`
  # cannot evaluate it at all. A real host would supply its own bootloader,
  # filesystems and hostname instead.
  boot.loader.grub.devices = [ "nodev" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  networking.hostName = "pz-example";
  system.stateVersion = "25.05";

  # Project Zomboid is a Steamworks title; its packages are unfree.
  nixpkgs.config.allowUnfree = true;

  networking.firewall.enable = true;

  services.project-zomboid-servers = {
    enable = true;

    # Saves grow without bound — point this at a large disk.
    dataDir = "/mnt/data/project-zomboid";

    # Take the whole catalogue, or cherry-pick:
    #   modpacks = { inherit (project-zomboid-servers.modpacks) vanilla-plus; };
    modpacks = project-zomboid-servers.modpacks;

    # Validate the shared install at every start (the default) so a first boot
    # fetches the game without a separate step.
    updateOnStart = true;

    servers.main = {
      modpack = "vanilla-plus";

      # Two UDP ports per instance, both unique across servers.
      defaultPort = 16261;
      udpPort = 16262;
      openFirewall = true;

      public = false;
      publicName = "Example PZ Server";
      maxPlayers = 16;

      # Inherit the pack's settings, then override.
      settings = {
        PVP = false;
        PauseEmpty = true;
      };

      sandbox = {
        Zombies = 2;
        DayLength = 6;
      };

      # The pack's defaults are a starting point; set what the host can afford.
      jvmOpts = "-Xmx6G -Xms3G";
      hardware = {
        memoryMax = "8G";
        memoryHigh = "7G";
        nice = 5;
      };

      # "always" (the default) so a deliberate `quit` is followed by a restart —
      # a clean exit is status 0, which `on-failure` would treat as success.
      restart = "always";

      # ttyd console on 127.0.0.1:7682, reachable through a proxy. Left off here;
      # see the README's "Reverse proxy" section for the upstream wiring.
      webConsole = false;
    };
  };
}
