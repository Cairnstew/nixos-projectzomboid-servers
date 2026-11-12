{
  description = "Declarative Project Zomboid dedicated servers for NixOS, plus a shared modpack catalogue";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # x86_64-linux ONLY, deliberately.
      #
      # `aarch64-linux` used to be declared here, which was wrong: the dedicated
      # server is a Steamworks title with no ARM Linux build, so `steamcmd` and
      # `steam-run` cannot be instantiated there and evaluating
      # `packages.aarch64-linux.project-zomboid-server` fails with "i686 Linux
      # package set can only be used with the x86 family". That made
      # `nix flake check --all-systems` fail, and would have broken any CI that
      # uses it.
      #
      # An ARM host is still fine: consume this module there and point
      # `package` at an x86_64 build under emulation, or run the server
      # elsewhere. What is not fine is advertising an output that cannot
      # evaluate.
      systems = [ "x86_64-linux" ];
      # Project Zomboid is a Steamworks title: steamcmd, steam-run and the
      # launcher wrapper are all unfree. Import nixpkgs with `allowUnfree` for
      # every system up front, so neither this flake's own checks nor a consumer
      # using the module has to remember it.
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            }
          )
        );

      # ── The module, as a let binding ───────────────────────────────────────
      # Defined outside the outputs attrset because `nixosModules.default` needs
      # to be the SAME value as `nixosModules.project-zomboid-servers`. Writing
      # `default = self.nixosModules.project-zomboid-servers` inside the
      # `nixosModules` attrset is an attrset self-reference, which Nix only
      # resolves under `rec`.
      pzModule =
        { pkgs, lib, ... }:
        {
          imports = [ ./modules/project-zomboid-servers.nix ];

          # The module file cannot reference `self`, so the launcher package is
          # supplied here. `mkDefault` yields to an explicit consumer choice,
          # which is why `package` defaults to null in options.nix rather than to
          # `pkgs.project-zomboid-server` — the latter would force every consumer
          # to add the overlay below.
          config.services.project-zomboid-servers = {
            package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.project-zomboid-server;
          };
        };

      # ── The Home Manager module, as a let binding ──────────────────────────
      # Same reason as `pzModule` above: `default` has to be the SAME value as
      # the named output, and an attrset self-reference needs `rec`.
      #
      # This is a plain Home Manager module, not a NixOS one: it reads the pack
      # back off `osConfig.services.project-zomboid-servers.clientHosts` and
      # writes the client's `~/Zomboid/Server/<name>.ini`. It is inert under
      # standalone Home Manager, which has no `osConfig`.
      pzHomeModule = import ./modules/home.nix;

      # ── Per-system outputs ─────────────────────────────────────────────────
      # Emitted FLAT (packages / apps / checks / devShells / formatter merged
      # together) rather than nested under `perSystem`, because `perSystem` is not
      # traversed by short-name lookups: with it, `nix build .#project-zomboid-server`
      # fails while the long `.#perSystem.x86_64-linux.packages.…` path works.
      perSystemOut = forEachSystem (
        pkgs:
        let
          inherit (pkgs) lib;

          modpackNames = lib.attrNames self.modpacks;

          # The shared prep/install logic, used by BOTH the NixOS module and the
          # standalone runner. `pz` is threaded in rather than re-imported inside
          # lib/prepare.nix: `import .` parses as `(import .) { … }` in Nix, and an
          # explicit argument makes the dependency obvious.
          pz-lib = import ./lib { inherit lib; };
          pz-prepare = import ./lib/prepare.nix {
            inherit lib pkgs;
            pz = pz-lib;
          };

          # The non-rotating ids/defaults, read from the one place they live so
          # the package, the runner and the NixOS module cannot drift apart.
          versions = builtins.fromJSON (builtins.readFile ./pkgs/project-zomboid-server/versions.json);

          # A complete per-server config carrying the same defaults the module's
          # options use, so `pz-lib.resolveServer` merges a pack identically
          # whether the server ends up under systemd or under `nix run`.
          #
          # Every field here must exist on a `resolveServer` result: the resolver
          # copies them through with `inherit (srv)`, so a field added to an
          # option but omitted here fails deep inside services.nix with
          # "attribute X missing" instead of at the option.
          serverDefaults = srvName: {
            name = srvName;
            description = "";
            modpack = null;
            workshopMods = [ ];
            mods = [ ];
            localMods = { };
            map = null;
            baseMap = versions.defaultBaseMap;
            mapOrder = {
              enable = true;
              priority = [ ];
              strict = false;
              dedupe = false;
            };
            spawn = {
              points = [ ];
              regions = [ ];
            };
            defaultPort = versions.defaultPort;
            udpPort = versions.defaultUdpPort;
            rconPort = 0;
            public = true;
            publicName = srvName;
            maxPlayers = versions.defaultMaxPlayers;
            open = true;
            upnp = false;
            selfManagedMods = true;
            softReset = false;
            settings = { };
            sandbox = { };
            whitelist = [ ];
            admins = [ ];
            adminAccount = null;
            secretFiles = { };
            passwordFile = null;
            compatibility = {
              build41 = false;
            };
            betaBranch = null;
            extraArgs = [ ];
            jvmOpts = "-Xmx4G -Xms2G";
            javaAgent = null;
            openFirewall = false;
            openRconFirewall = false;
            autoStart = true;
            restart = "always";
            schedule = {
              start = [ ];
              persistent = false;
            };
            idleStop = {
              enable = false;
              timeout = "30m";
            };
            hardware = { };
            extraServiceConfig = { };
            managementSystem = {
              systemd-socket.enable = true;
            };
            webConsole = true;
            port = null;
            clientHost = {
              enable = false;
              name = "servertest";
            };
            enable = true;
          };

          # The standalone runner, with the pack resolved at EVAL time. Merging a
          # pack means merging Nix values and rendering `Key=value` lines, so the
          # pack cannot be a runtime flag without shipping the whole catalogue into
          # the script and reimplementing the merge in shell. Hence one app per
          # pack (`pz-<pack>`) plus an unmodded `pz-dedicated-server`.
          mkRunner =
            {
              srvName,
              modpack ? null,
              server ? { },
            }:
            pkgs.callPackage ./pkgs/project-zomboid-runner {
              inherit modpack;
              # Not in pkgs, so callPackage cannot infer it.
              project-zomboid-server = pkgs.callPackage ./pkgs/project-zomboid-server { };
              pz-prepare = pz-prepare;
              resolvedServer = pz-lib.resolveServer self.modpacks srvName (
                (serverDefaults srvName)
                // {
                  inherit modpack;
                }
                // server
              );
            };

        in
        {
          packages = {
            project-zomboid-server = pkgs.callPackage ./pkgs/project-zomboid-server { };
            project-zomboid-client-mods = pkgs.callPackage ./pkgs/project-zomboid-client-mods { };
            project-zomboid-runner = mkRunner { srvName = "pz"; };
            inherit (pkgs) steamcmd;
          };

          # ── Apps ────────────────────────────────────────────────────────────
          # Run a dedicated server:
          #   nix run .#pz-dedicated-server -- myserver    (unmodded)
          #   nix run .#pz-vanilla-plus          -- myserver    (pack baked in)
          # Browse the catalogue:
          #   nix run .#pz-modpack -- list | show <pack>
          apps = {
            pz-dedicated-server = {
              type = "app";
              program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.project-zomboid-runner;
            };

            pz-maps = {
              type = "app";
              program = lib.getExe (
                pkgs.writeShellApplication {
                  name = "pz-maps";
                  runtimeInputs = [ pkgs.python3 ];
                  text = ''
                    # A thin, discoverable wrapper so `Map=` can be inspected and
                    # audited without starting a server — the "why is this mod's
                    # map not loading" tool, and the thing to run in CI to prove a
                    # pack has no duplicate-map clashes.
                    exec python3 ${./scripts/pz_maps.py} "$@"
                  '';
                }
              );
            };

            # A small CLI over the catalogue: what does a pack install, and what
            # would it render into a server's .ini / SandboxVars?
            pz-modpack = {
              type = "app";
              program = lib.getExe (
                pkgs.writeShellApplication {
                  name = "pz-modpack";
                  runtimeInputs = [
                    pkgs.jq
                    pkgs.coreutils
                  ];
                  text = ''
                    catalogue="$(cat ${pkgs.writeText "modpacks.json" (builtins.toJSON self.modpacks)})"

                    usage() {
                      echo "usage: pz-modpack [list|show <pack>]" >&2
                      echo >&2
                      echo "  list          every modpack in the catalogue" >&2
                      echo "  show <pack>   that pack's Workshop items, mods and settings" >&2
                      exit 2
                    }

                    case "''${1-}" in
                      list)
                        echo "$catalogue" | jq -r 'keys[]'
                        ;;
                      show)
                        pack="''${2-}"
                        [ -n "$pack" ] || usage
                        echo "$catalogue" | jq -r --arg p "$pack" '
                          if has($p) then
                            .[$p]
                            | "description: \(.description)",
                              "workshopMods:",
                              (if (.workshopMods | length) == 0 then "  (none)"
                               else (.workshopMods[] | "  \(.id)  \(.title // "untitled")") end),
                              "mods: \(if (.mods|length)==0 then "(none)" else (.mods|join(", ")) end)",
                              "defaultSettings: \(.defaultSettings|tojson)",
                              "defaultSandbox: \(.defaultSandbox|tojson)"
                          else
                            "pz-modpack: no such modpack: \($p)\navailable: \(keys|join(", "))" | error
                          end
                        '
                        ;;
                      -h|--help|help)
                        usage
                        ;;
                      *)
                        usage
                        ;;
                    esac
                  '';
                }
              );
            };

            # Steam Workshop helpers over a collection and the catalogue:
            #   nix run .#pz-workshop -- expand <collection-id>   draft a pack (mods prefilled)
            #   nix run .#pz-workshop -- resolve {collection,pack} <id>   internal Mod IDs
            #   nix run .#pz-workshop -- emit <pack>              paste-ready list
            # There is no "publish" command: Steam has no public write API for
            # collections. See scripts/pz_workshop.py.
            pz-workshop = {
              type = "app";
              program = lib.getExe (
                pkgs.writeShellApplication {
                  name = "pz-workshop";
                  runtimeInputs = [ pkgs.python3 ];
                  text = ''
                    # A pack is Nix data; inject the catalogue as JSON the same
                    # way `pz-modpack` does, so `emit` needs no Nix interpreter.
                    export PZ_MODPACKS_JSON=${pkgs.writeText "modpacks.json" (builtins.toJSON self.modpacks)}

                    # A Steam Web API key, as a FILE PATH, for a higher rate budget
                    # on the item lookups. Deliberately NOT a NixOS module option:
                    # nothing on a server ever reads it (Workshop CONTENT still
                    # authenticates as an account via `steamLogin`), and this app
                    # runs on a workstation, where `nix run` never evaluates the
                    # module — so an option there would be config that reads
                    # nothing. The env var also passes through on its own, so this
                    # is only a notice. Never the key itself: the value is read at
                    # run time, keeping it out of the store path and `ps`.
                    if [ -n "''${PZ_STEAM_API_KEY_FILE-}" ]; then
                      echo "pz-workshop: using the Web API key from $PZ_STEAM_API_KEY_FILE" >&2
                    fi

                    exec python3 ${./scripts/pz_workshop.py} "$@"
                  '';
                }
              );
            };

            # Fetch a pack's Workshop mods onto a CLIENT machine. The default
            # target is the game's local mods folder, which the client loads with
            # no Steam subscription; `--steam-library` pre-seeds the library
            # instead (invisible to the client until subscribed). The item ->
            # local-mod mapping is the same reason the server's snake_case and
            # camelCase lists are kept apart. See scripts/pz_client_mods.py.
            pz-client-mods = {
              type = "app";
              program = lib.getExe (
                pkgs.writeShellApplication {
                  name = "pz-client-mods";
                  text = ''
                    # The pack catalogue is Nix data; inject it as JSON so the
                    # `pz-client-mods <pack>` convenience works. The tool itself
                    # is the shared package, so the module and this app run one
                    # implementation.
                    export PZ_MODPACKS_JSON=${pkgs.writeText "modpacks.json" (builtins.toJSON self.modpacks)}
                    exec ${lib.getExe (pkgs.callPackage ./pkgs/project-zomboid-client-mods { })} "$@"
                  '';
                }
              );
            };
          }
          # One app per catalogue pack: `nix run .#pz-vanilla-plus -- <name>`.
          #
          # Merged onto the attrset above so this stays ONE attribute
          # (`apps = { ... } // ...;`). It cannot simply be listed inside the
          # literal for two reasons: Nix attrsets are not self-recursive without
          # `rec`, and a `//` continuation line is not a comment — Nix comments
          # are `#`, while `//` is the integer-division operator.
          // lib.listToAttrs (
            map (
              pack:
              lib.nameValuePair "pz-${pack}" {
                type = "app";
                program = lib.getExe (mkRunner {
                  srvName = "pz";
                  modpack = pack;
                });
              }
            ) modpackNames
          );

          formatter = pkgs.nixfmt-rfc-style;

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-rfc-style
              pkgs.python3
              pkgs.shellcheck
              pkgs.deadnix
              pkgs.statix
            ];
            shellHook = ''
              echo "pz dev shell — nix flake check, nixfmt, shellcheck, deadnix, statix"
              echo "  catalogue:  nix run .#pz-modpack -- list"
            '';
          };

          checks = import ./checks {
            inherit (nixpkgs) lib;
            inherit
              pkgs
              self
              modpackNames
              pz-lib
              pz-prepare
              serverDefaults
              versions
              ;
            nixpkgsLib = nixpkgs.lib;
          };
        }
      );

      # `perSystemOut` is keyed BY SYSTEM (`{ x86_64-linux = { … }; … }`), so each
      # flake output has to be re-keyed by system too. That is exactly the shape
      # the flake schema wants, and it is what makes the short form work:
      # `nix build .#project-zomboid-server` resolves
      # `packages.<current-system>.project-zomboid-server`.
      perSystemAttr =
        attr: nixpkgs.lib.genAttrs systems (system: (perSystemOut.${system}).${attr} or { });
    in
    {
      # ── The modpack catalogue ──────────────────────────────────────────────
      # Pure data: modpack name -> pack. No module, no `my.*`, no `pkgs`.
      # Consumers map it straight into the module's `modpacks` option.
      modpacks = import ./modpacks { lib = nixpkgs.lib; };

      # ── The shared library ─────────────────────────────────────────────────
      # renderIniLines / renderSandbox / resolveServer / mkProxyUpstreams, plus
      # `tests.eval` for evaluating a configuration without booting a VM.
      lib = (import ./lib { lib = nixpkgs.lib; }) // {
        # No `builtins.currentSystem` anywhere in this output: it is an impure
        # builtin, so referencing it would make every consumer's pure flake
        # evaluation of `lib` fail.
        tests = import ./lib/tests.nix { lib = nixpkgs.lib; };
      };

      # ── The module ──────────────────────────────────────────────────────────
      nixosModules = {
        project-zomboid-servers = pzModule;
        # Alias, because `default` is the conventional opt-in name.
        default = pzModule;
      };

      # The Home Manager half: `clientHosts` are RENDERED by the NixOS module
      # above, but they live in a user's `~/Zomboid`, so they are INSTALLED here.
      # See modules/home.nix for why the split exists.
      homeModules = {
        project-zomboid-servers = pzHomeModule;
        default = pzHomeModule;
      };

      # Lets `pkgs.project-zomboid-server` resolve for consumers who prefer the
      # overlay to the module's built-in default.
      overlays.default = final: _prev: {
        project-zomboid-server = final.callPackage ./pkgs/project-zomboid-server { };
        project-zomboid-client-mods = final.callPackage ./pkgs/project-zomboid-client-mods { };
      };

      packages = perSystemAttr "packages";
      apps = perSystemAttr "apps";
      checks = perSystemAttr "checks";
      devShells = perSystemAttr "devShells";
      # Per-system attrset, which the flake schema resolves against the
      # evaluation platform. `builtins.currentSystem` would be simpler but it is
      # an impure builtin, so referencing it fails under `nix flake check`.
      formatter = perSystemAttr "formatter";
    };
}
