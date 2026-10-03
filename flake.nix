{
  description = "Declarative Project Zomboid dedicated servers for NixOS, plus a shared modpack catalogue";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
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

          # Evaluate a NixOS configuration containing this module, per system.
          # lib/tests.nix exposes `{ eval, … }`, so take `.eval`.
          eval-config = (import ./lib/tests.nix { lib = nixpkgs.lib; }).eval;

          # ── Catalogue validation ───────────────────────────────────────────
          # Every pack must be plain data. A stray `config` or option path would
          # otherwise fail deep inside a consumer's evaluation with an
          # unhelpful message, so it is checked here at `nix flake check` time.
          modpackProblem =
            name:
            let
              pack = self.modpacks.${name};
              required = [
                "description"
                "workshopMods"
                "mods"
                "defaultSettings"
                "defaultSandbox"
              ];
              missing = builtins.filter (k: !(pack ? ${k})) required;
              scalar = v: builtins.isBool v || builtins.isInt v || builtins.isFloat v || builtins.isString v;
              allScalar = attrs: builtins.all scalar (builtins.attrValues attrs);
              isMod =
                m:
                builtins.isAttrs m
                && (m ? id)
                && builtins.isString m.id
                && (!(m ? title) || builtins.isString m.title);
            in
            if missing != [ ] then
              "is missing required key(s): ${lib.concatStringsSep ", " missing}"
            else if !(builtins.isList pack.workshopMods) then
              "workshopMods must be a list"
            else if !(builtins.all isMod pack.workshopMods) then
              "workshopMods must be a list of { id = \"<digits>\"; title = ...; }"
            else if !(allScalar pack.defaultSettings) || !(allScalar pack.defaultSandbox) then
              "defaultSettings and defaultSandbox must map to bool/int/float/str"
            else
              null;

          catalogueProblems = lib.filter (s: s != null) (lib.map modpackProblem modpackNames);

          # ── Module evaluation check ────────────────────────────────────────
          # Asserts, IN NIX, that a two-server configuration produces the right
          # units, ports and Exec paths. Nix assertions rather than shell + jq
          # because a failure then reads as a Nix error with a real traceback;
          # the trivial derivation is only there to give `nix flake check`
          # something to build.
          #
          # This is the check that catches a dangling `Requires=` on a unit that
          # was never defined, and an `ExecStart` that is not a store path
          # (203/EXEC) — both of which shipped broken in the module this was
          # ported from.
          moduleEvalResult =
            let
              evaluated = eval-config {
                inherit pkgs;
                config = {
                  services.project-zomboid-servers = {
                    enable = true;
                    dataDir = "/var/lib/project-zomboid";
                    modpacks = self.modpacks;
                    web.enable = false;
                    servers = {
                      alpha = {
                        modpack = "vanilla-plus";
                        defaultPort = 16261;
                        udpPort = 16262;
                        openFirewall = true;
                        settings.PVP = false;
                      };
                      beta = {
                        modpack = "survival-hard";
                        defaultPort = 16271;
                        udpPort = 16272;
                      };
                    };
                  };
                };
              };

              cfg = evaluated.config.services.project-zomboid-servers;
              services = evaluated.config.systemd.services;
              sockets = evaluated.config.systemd.sockets;
              firewallUdp = lib.sort (a: b: a < b) (
                lib.toList (evaluated.config.networking.firewall.allowedUDPPorts or [ ])
              );

              envOf = unit: (services.${unit}.serviceConfig.Environment or [ ]);
              hasEnv = unit: prefix: builtins.any (e: lib.hasPrefix prefix e) (envOf unit);
              storePath = p: lib.hasPrefix "/nix/store/" (toString p);

              # A unit may only depend on units THIS MODULE also defines.
              #
              # Two things this deliberately ignores:
              #   * the `.service` / `.socket` suffix, which systemd's own options
              #     carry but the config attr names do not (`project-zomboid-install`
              #     is `project-zomboid-install.service` on the wire);
              #   * dependencies outside this module's namespace, e.g. the
              #     `systemd-logind.service` that NixOS adds to anything with a
              #     `User =`, which is provided by systemd rather than by Nix.
              danglingDeps =
                let
                  mine = name: lib.hasPrefix "project-zomboid-" name && name != "project-zomboid-install";
                  allDeps = lib.concatMap (name: services.${name}.requires or [ ]) (lib.attrNames services);
                  ownDeps = lib.filter (d: mine (lib.removeSuffix ".service" (lib.removeSuffix ".socket" d))) (
                    lib.unique allDeps
                  );
                  known = map (n: lib.removeSuffix ".service" (lib.removeSuffix ".socket" n)) (
                    lib.attrNames services ++ lib.attrNames sockets
                  );
                in
                lib.filter (
                  d: !(lib.elem (lib.removeSuffix ".service" (lib.removeSuffix ".socket" d)) known)
                ) ownDeps;

              perServer = lib.concatMap (
                name:
                let
                  unit = "project-zomboid-${name}";
                  sc = services.${unit}.serviceConfig or { };
                in
                [
                  (lib.optionalString (services ? ${unit} == false) "no unit ${unit}")
                  (lib.optionalString (sockets ? ${unit} == false) "no console socket for ${name}")
                  (lib.optionalString (
                    !(storePath (sc.ExecStart or ""))
                  ) "${unit}.ExecStart is not an absolute store path")
                  (lib.optionalString (
                    !(storePath (sc.ExecStartPre or ""))
                  ) "${unit}.ExecStartPre is not an absolute store path")
                  (lib.optionalString (
                    !(storePath (sc.ExecStop or ""))
                  ) "${unit}.ExecStop is not an absolute store path")
                  # jvmOpts must reach the unit, not sit unused in the config.
                  (lib.optionalString (
                    !hasEnv unit "PZ_JVM_OPTS="
                  ) "${unit} has no PZ_JVM_OPTS — jvmOpts did not reach the unit")
                  (lib.optionalString (!hasEnv unit "PZ_SERVER_DIR=") "${unit} has no PZ_SERVER_DIR")
                ]
              ) (lib.attrNames cfg.servers);

              # Force `config.assertions`. NixOS evaluates them as part of building
              # the system toplevel, so a check that only reads systemd.services
              # never touches them — which means a module whose every assertion
              # fails still "passes". Reading them here is what makes this check
              # test the assertions at all.
              # `config.assertions` is a LIST in current nixpkgs (modules append to
              # it) and was an attrset in older ones, so accept either shape.
              rawAssertions = evaluated.config.assertions or [ ];
              allAssertions =
                if builtins.isList rawAssertions then rawAssertions else lib.attrValues rawAssertions;
              failedAssertions = lib.filter (a: !a.assertion) allAssertions;

              # Each failed assertion becomes its own failure line, with the
              # module's own message — which is the whole point of reading them.
              assertionFailures = lib.concatMap (
                a: lib.optionalString (!a.assertion) "assertion failed: ${a.message}"
              ) failedAssertions;

              staticFailures = [
                # Guard against the check passing vacuously: if the module ever
                # stops contributing assertions, fail loudly rather than silently
                # checking nothing.
                (lib.optionalString (
                  allAssertions == [ ]
                ) "the module contributed no assertions, so this check is vacuous — is config.nix still imported?")
                (lib.optionalString (
                  services ? project-zomboid-install == false
                ) "no project-zomboid-install unit, yet the servers Require it")
                (lib.optionalString (
                  danglingDeps != [ ]
                ) "units require undefined dependencies: ${lib.concatStringsSep ", " danglingDeps}")
                (lib.optionalString
                  (
                    firewallUdp != [
                      16261
                      16262
                    ]
                  )
                  "firewall opened unexpected UDP ports: ${lib.concatStringsSep ", " firewallUdp} (only alpha opted in)"
                )
                (lib.optionalString (
                  !(cfg.modpacks ? vanilla-plus) || !(cfg.modpacks ? survival-hard)
                ) "the catalogue was not merged into modpacks")
              ];

              # ── Second scenario: web consoles + the tmux backend ────────────
              # A separate evaluation, because the first one leaves web.enable
              # false — and that hid three real bugs for a while (mkMerge over a
              # list of { name, value; } pairs, a `readOnly` option that also had
              # a `default`, and `resolveServer` not carrying `webConsole`). Any
              # branch a check never evaluates is a branch that can rot.
              webEval = eval-config {
                inherit pkgs;
                config.services.project-zomboid-servers = {
                  enable = true;
                  dataDir = "/var/lib/project-zomboid";
                  modpacks = self.modpacks;
                  web = {
                    enable = true;
                    username = "pz";
                    passwordFile = "/run/agenix/pz-console";
                  };
                  servers = {
                    # tmux backend: must produce NO console socket unit.
                    tmux-server = {
                      modpack = "survival-hard";
                      defaultPort = 16261;
                      udpPort = 16262;
                      managementSystem = {
                        systemd-socket.enable = false;
                        tmux.enable = true;
                      };
                    };
                    # Default (socket) backend, with a web console.
                    socket-server = {
                      modpack = "vanilla-plus";
                      defaultPort = 16271;
                      udpPort = 16272;
                    };
                  };
                };
              };

              webSvcs = webEval.config.systemd.services;
              webSocks = webEval.config.systemd.sockets;
              webUpstreams = webEval.config.services.project-zomboid-servers.webConsoleUpstreams or [ ];

              webFailures = [
                (lib.optionalString (
                  webSvcs ? project-zomboid-socket-server-web == false
                ) "web console unit missing for socket-server")
                (lib.optionalString (
                  webSocks ? project-zomboid-socket-server == false
                ) "no console socket for socket-server")
                # The tmux server must NOT also get a socket unit — two claims on
                # the same stdin is exactly what the module's assertion guards.
                (lib.optionalString (
                  webSocks ? project-zomboid-tmux-server
                ) "the tmux server also got a console socket unit")
                (lib.optionalString (webSvcs ? project-zomboid-tmux-server == false) "no unit for tmux-server")
                (lib.optionalString (
                  builtins.length webUpstreams != 2
                ) "expected 2 proxy upstreams, got ${toString (builtins.length webUpstreams)}")
                (lib.optionalString (
                  !(builtins.elem "pz-socket-server" (map (u: u.name) webUpstreams))
                ) "no proxy upstream named pz-socket-server")
                (lib.optionalString (
                  webEval.config.networking.firewall.allowedTCPPorts != [ ]
                ) "web consoles opened TCP ports without web.openFirewall")
              ];

              failures = lib.filter (s: s != null && s != "") (
                perServer ++ staticFailures ++ assertionFailures ++ webFailures
              );
            in
            if failures == [ ] then
              pkgs.runCommand "pz-module-eval-check" { } ''
                echo "module eval ok"
                touch "$out"
              ''
            else
              throw ''
                services.project-zomboid-servers: the module-eval check failed:

                  ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
              '';
        in
        {
          packages = {
            project-zomboid-server = pkgs.callPackage ./pkgs/project-zomboid-server { };
            inherit (pkgs) steamcmd;
          };

          # A small CLI over the catalogue: what does a pack install, and what
          # would it render into a server's .ini / SandboxVars?
          apps.pz-modpack = {
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

          checks = {
            launcher = pkgs.callPackage ./pkgs/project-zomboid-server { };

            modpack-catalogue =
              if catalogueProblems != [ ] then
                throw ''
                  The modpack catalogue is malformed:

                    ${lib.concatStringsSep "\n" (map (p: "  - modpacks.${p}") catalogueProblems)}

                  Every pack in modpacks/ must be plain data with the keys
                  description / workshopMods / mods / defaultSettings /
                  defaultSandbox. See modpacks/default.nix.
                ''
              else
                pkgs.runCommand "pz-modpack-catalogue-check" { } ''
                  echo "modpack catalogue ok: ${lib.concatStringsSep ", " modpackNames}"
                  touch "$out"
                '';

            module-eval = moduleEvalResult;
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

      # Lets `pkgs.project-zomboid-server` resolve for consumers who prefer the
      # overlay to the module's built-in default.
      overlays.default = final: _prev: {
        project-zomboid-server = final.callPackage ./pkgs/project-zomboid-server { };
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
