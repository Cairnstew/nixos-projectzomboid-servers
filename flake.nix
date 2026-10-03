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

          # The shared prep/install logic, used by BOTH the NixOS module and the
          # standalone runner. `pz` is threaded in rather than re-imported inside
          # lib/prepare.nix: `import .` parses as `(import .) { … }` in Nix, and an
          # explicit argument makes the dependency obvious.
          pz-lib = import ./lib { inherit lib; };
          pz-prepare = import ./lib/prepare.nix {
            inherit lib pkgs;
            pz = pz-lib;
          };

          # Evaluate a NixOS configuration containing this module, per system.
          # lib/tests.nix exposes `{ eval, … }`, so take `.eval`.
          eval-config = (import ./lib/tests.nix { lib = nixpkgs.lib; }).eval;

          # A complete per-server config carrying the same defaults the module's
          # options use, so `pz-lib.resolveServer` merges a pack identically
          # whether the server ends up under systemd or under `nix run`.
          serverDefaults = srvName: {
            name = srvName;
            description = "";
            modpack = null;
            workshopMods = [ ];
            mods = [ ];
            map = "Muldraugh, KY";
            defaultPort = 16261;
            udpPort = 16262;
            rconPort = 0;
            public = true;
            publicName = srvName;
            maxPlayers = 32;
            open = true;
            settings = { };
            sandbox = { };
            whitelist = [ ];
            admins = [ ];
            passwordFile = null;
            jvmOpts = "-Xmx4G -Xms2G";
            openFirewall = false;
            autoStart = true;
            restart = "always";
            hardware = { };
            extraServiceConfig = { };
            managementSystem = {
              systemd-socket.enable = true;
            };
            webConsole = false;
            port = null;
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

            # ── Does the prep script actually WORK? ───────────────────────────
            # module-eval only checks that the units are shaped correctly; it never
            # runs them. This check executes the real prep script against a
            # pre-seeded server home and asserts the behaviour that is easy to get
            # wrong and expensive to discover in production:
            #
            #   * PZ's world-identity keys (Seed, ResetID, ServerPlayerID) survive;
            #   * the Nix-rendered base config lands in the .ini;
            #   * a runtime override (as the standalone runner passes) wins;
            #   * SandboxVars.lua is written and is shaped like a Lua table;
            #   * Workshop mods are symlinked, and stale ones unlinked.
            #
            # Cheap on purpose: a plain derivation, not a VM. The game binary is
            # never needed, because the prep script only touches config and links.
            #
            # NOTE the shell variable is `srv`, never `name`: in a Nix derivation
            # `$name` is the DERIVATION's name from the build environment, so using
            # it here silently points the assertions at a different path than the
            # one the prep script wrote — a check that passes for the wrong reason.
            prep-roundtrip =
              let
                srv = "roundtrip";
                server = pz-lib.resolveServer self.modpacks srv (
                  (serverDefaults srv)
                  // {
                    modpack = "vanilla-plus";
                    settings = {
                      PVP = true;
                      PauseEmpty = true;
                    };
                  }
                );
                prep = pz-prepare.mkPrepScript {
                  inherit server;
                  iniBase = pz-prepare.mkIniBase { inherit server; };
                  name = "pz-prep-roundtrip";
                };
              in
              pkgs.runCommand "pz-prep-roundtrip-check"
                {
                  nativeBuildInputs = [
                    pkgs.coreutils
                  ];
                }
                ''
                  # `srv` is a NIX binding, so it must be pushed into the shell
                  # explicitly. Two traps in one line of thought: `$name` here would
                  # be the DERIVATION's name from the build environment (not any
                  # binding), and a Nix-only binding used as `$srv` would simply be
                  # empty — either way the check would seed and assert against one
                  # path while the prep script wrote another, and pass for the wrong
                  # reason.
                  srv="${srv}"
                  root="$TMPDIR/pz"
                  data="$root/data"
                  server_root="$root/server"
                  mkdir -p "$data/$srv/Zomboid/Server"

                  # A world that already exists. These keys are PZ's, not ours.
                  cat > "$data/$srv/Zomboid/Server/$srv.ini" <<'SEED_INI'
                  Seed=world-seed-abcdef
                  ResetID=424242
                  ServerPlayerID=1234567
                  LastModified=2026-01-01
                  DefaultPort=11111
                  SEED_INI

                  # Fake the shared install so the symlink branch has something to
                  # link to.
                  mkdir -p "$server_root/steamapps/workshop/content/108600/2625441155/mods"
                  touch "$server_root/steamapps/workshop/content/108600/2625441155/mods/.keep"

                  # A stale symlink for a mod that is NO LONGER downloaded. The
                  # prep script must unlink it rather than leave a dangling entry
                  # PZ would try to load.
                  stale="$data/$srv/Zomboid/Workshop/content/108600/9999999999"
                  mkdir -p "$(dirname "$stale")"
                  ln -s "$server_root/steamapps/workshop/content/108600/9999999999" "$stale"

                  export PZ_DATA_DIR="$data"
                  export PZ_SERVER_DIR="$server_root"
                  export PZ_SERVER_NAME="$srv"

                  # Runtime overrides, exactly as the runner passes them.
                  ${prep}/bin/pz-prep-roundtrip \
                    "DefaultPort=16299" \
                    "Map=Rosewood, OR"

                  ini="$data/$srv/Zomboid/Server/$srv.ini"
                  sandbox="$data/$srv/Zomboid/Server/${srv}_SandboxVars.lua"

                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  # ── World identity must survive ──────────────────────────────
                  grep -qx 'Seed=world-seed-abcdef' "$ini" || fail "Seed was lost — the .ini was overwritten, not merged"
                  grep -qx 'ResetID=424242' "$ini" || fail "ResetID was lost — the world would be renumbered"
                  grep -qx 'ServerPlayerID=1234567' "$ini" || fail "ServerPlayerID was lost"
                  grep -qx 'LastModified=2026-01-01' "$ini" || fail "LastModified was lost"

                  # ── Our config landed, and the runtime override won ──────────
                  grep -qx 'DefaultPort=16299' "$ini" || fail "runtime DefaultPort override did not win (got: $(grep '^DefaultPort=' "$ini" || true))"
                  grep -qx 'Map=Rosewood, OR' "$ini" || fail "a Map value containing a comma and a space was mangled"
                  grep -qx 'UDPPort=16262' "$ini" || fail "the Nix-rendered base config did not land (no UDPPort)"
                  grep -qx 'PVP=true' "$ini" || fail "a server-level setting did not land, or a bool rendered as True"
                  grep -q '^WorkshopItems=.*2625441155' "$ini" || fail "the modpack's Workshop items are not in WorkshopItems"

                  # ── SandboxVars ──────────────────────────────────────────────
                  [ -f "$sandbox" ] || fail "no _SandboxVars.lua written"
                  head -1 "$sandbox" | grep -qx 'SandboxVars = {' || fail "_SandboxVars.lua does not open a SandboxVars table"
                  tail -1 "$sandbox" | grep -qx '}' || fail "_SandboxVars.lua does not close the table"
                  grep -qE '^ +Zombies = [0-9]+$' "$sandbox" || fail "the modpack's sandbox vars did not land"

                  # ── Workshop symlinks ───────────────────────────────────────
                  link="$data/$srv/Zomboid/Workshop/content/108600/2625441155"
                  [ -L "$link" ] || fail "no symlink for a downloaded Workshop item"
                  [ -e "$link" ] || fail "the Workshop symlink dangles"
                  [ ! -e "$stale" ] || fail "a symlink for an undownloaded mod was left behind (would dangle)"

                  echo "prep roundtrip ok: world identity preserved, config merged, sandbox written, mods linked"
                  touch "$out"
                '';
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
