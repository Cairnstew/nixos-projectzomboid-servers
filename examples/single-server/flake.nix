{
  description = "Single Project Zomboid server on the vanilla-plus pack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Replace with the real remote once this is published:
    #   project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers";
    project-zomboid-servers.url = "path:/home/seanc/Projects/nixos-projectzomboid-servers";
  };

  outputs =
    { nixpkgs, project-zomboid-servers, ... }:
    let
      system = "x86_64-linux";

      # Unfree: Project Zomboid is a Steamworks title. Imported here rather than
      # taken from `nixpkgs.legacyPackages`, which is unfree-restricted and
      # yields a derivation Nix then reports as belonging to no system.
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
        specialArgs = { inherit project-zomboid-servers; };
      };

      # Evaluate this example's configuration and assert the server unit came out
      # as intended. Cheaper than a toplevel check, which would build an entire
      # NixOS closure — and it is the same assertion style as the parent flake's
      # own `module-eval` check.
      checks.example-evaluates =
        let
          # Deliberately `nixosSystem` rather than the parent flake's
          # `lib.tests.eval`: this configuration already imports the flake's own
          # nixosModules (which supplies `package`), and the helper would inject a
          # second `mkDefault` for the same option — a priority conflict. Going
          # through `nixosSystem` is also exactly the path a real consumer takes,
          # so the check exercises what consumers actually get. Evaluation is
          # cheap; only building `system.build.toplevel` is not.
          evaluated = nixpkgs.lib.nixosSystem {
            inherit system;
            pkgs = pkgs;
            specialArgs = { inherit project-zomboid-servers; };
            modules = [ ./configuration.nix ];
          };

          services = evaluated.config.systemd.services;
          unit = services."project-zomboid-main" or { };
          sc = unit.serviceConfig or { };

          problems = builtins.filter (s: s != null && s != "") [
            (if unit ? serviceConfig then null else "no project-zomboid-main unit")
            (if unit.enable or false then null else "project-zomboid-main is not enabled")
            (if (sc.Restart or null) == "always" then null else "Restart is not \"always\"")
            (
              if builtins.elem "PZ_JVM_OPTS=-Xmx6G -Xms3G" (sc.Environment or [ ]) then
                null
              else
                "jvmOpts did not reach the unit's Environment"
            )
            (if (services ? project-zomboid-install || false) then null else "no project-zomboid-install unit")
            (
              if evaluated.config.systemd.sockets ? project-zomboid-main then
                null
              else
                "no console socket for project-zomboid-main"
            )
          ];
        in
        if problems == [ ] then
          pkgs.runCommand "pz-example-evaluates" { } ''
            echo "examples/single-server: project-zomboid-main evaluated as expected"
            touch "$out"
          ''
        else
          throw ''
            examples/single-server/configuration.nix did not produce the expected units:
              ${builtins.concatStringsSep "\n" (map (p: "  - ${p}") problems)}
          '';
    };
}
