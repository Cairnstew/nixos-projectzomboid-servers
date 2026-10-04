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

          # Evaluate a NixOS configuration containing this module, per system.
          # lib/tests.nix exposes `{ eval, … }`, so take `.eval`.
          eval-config = (import ./lib/tests.nix { lib = nixpkgs.lib; }).eval;

          # The messages of every assertion that FAILED for a given extra config,
          # as one string. A failing assertion does not abort evaluation — it is
          # collected in `config.assertions` with `assertion = false` and read back
          # here — so this is how a check can assert that a guard trips.
          failedMessages =
            extra:
            let
              evaluated = eval-config {
                inherit pkgs;
                config.services.project-zomboid-servers = {
                  enable = true;
                  inherit (extra) servers;
                  # `or { }` rather than `inherit`, because a caller testing only
                  # `servers` does not pass a `modpacks` key at all.
                  modpacks = extra.modpacks or { };
                };
              };
            in
            lib.concatStringsSep "\n---\n" (
              map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions)
            );

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
              #
              # `optionals … [ … ]`, NOT `optionalString`: this list is `++`-ed
              # into `failures` below, so every element must itself be a LIST.
              # `lib.concatMap` over `optionalString` looks correct and is not —
              # `concatMap` is `concat . map`, and `concat` expects a list. With
              # no failures `concat [ ]` returns `[]` without complaint, so the
              # bug hides until the day an assertion fails, at which point the
              # check dies with "expected a list but found a string" instead of
              # printing the message it exists to print.
              assertionFailures = lib.concatMap (
                a: lib.optionals (!a.assertion) [ "assertion failed: ${a.message}" ]
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

            # ── The option reference is complete ───────────────────────────────
            # A reference that has silently fallen behind the module is worse than
            # no reference: a consumer reads it, concludes an option does not
            # exist, and works around it. `docs/options.md` is therefore checked
            # against `modules/options.nix`.
            #
            # Name-level, by extracting `name = mkOption` / `mkEnableOption` from
            # the source with grep. Deliberately not generated from the evaluated
            # option tree: options inside an `attrsOf` submodule (`servers.*`,
            # `modpacks.*`, `web.*`) are not statically enumerable — `getSubOptions`
            # and `getSubModules` both refuse to cooperate — so a generated
            # reference could not cover the per-server options, which are most of
            # them.
            #
            # One direction only: every DECLARED option must be documented. The
            # reverse is not checked, because option names in prose ("`port`",
            # "`name`") cannot be told apart from option references reliably.
            options-documented =
              pkgs.runCommand "pz-options-documented-check"
                {
                  nativeBuildInputs = [
                    pkgs.coreutils
                    pkgs.gnugrep
                  ];
                  OPTIONS_NIX = ./modules/options.nix;
                  OPTIONS_DOC = ./docs/options.md;
                }
                ''
                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  # Every declaration in the source, deduplicated.
                  declared="$(grep -oE '^[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*=[[:space:]]*mk(Option|EnableOption)' \
                    "$OPTIONS_NIX" \
                    | sed -E 's/^[[:space:]]*([A-Za-z][A-Za-z0-9_.-]*)[[:space:]]*=.*/\1/' \
                    | sort -u)"

                  count="$(printf '%s\n' "$declared" | grep -c . || true)"
                  # A regex change that matches nothing would make this check
                  # pass for the wrong reason, which is the failure mode a
                  # completeness check cannot afford.
                  [ "$count" -ge 60 ] \
                    || fail "only $count option declarations were found in options.nix -- has the declaration style changed? This check would pass vacuously."

                  missing=""
                  for opt in $declared; do
                    grep -qF -- "$opt" "$OPTIONS_DOC" || missing="$missing $opt"
                  done

                  if [ -n "$missing" ]; then
                    fail "options declared in modules/options.nix but absent from docs/options.md:$missing"
                  fi

                  # The document must actually be the reference, not a stub.
                  grep -q 'servers.<name>' "$OPTIONS_DOC" \
                    || fail "docs/options.md has no servers.<name> section"
                  grep -q 'services.project-zomboid-servers' "$OPTIONS_DOC" \
                    || fail "docs/options.md never names the option namespace"

                  echo "options documented ok: $count declarations, all present in docs/options.md"
                  touch "$out"
                '';

            # ── The non-flake entry point actually works ──────────────────────
            # `default.nix` is what a consumer without flakes imports, and it was
            # entirely broken: the top level was a function of `{ flake }`, so
            # `(import (builtins.fetchTarball …)).nixosModules.default` — the
            # command the file's own comment advertised — failed with "expected a
            # set but found a function". It stayed broken because nothing in this
            # flake referenced it, so `nix flake check` was blind to it.
            #
            # This check imports it the way such a consumer does and asserts the
            # configuration comes out right. Only the parts that do NOT need
            # `<nixpkgs>` are reachable here: pure flake evaluation cannot look up
            # a channel path ("cannot look up '<nixpkgs>' in pure evaluation
            # mode"), so `modpacks` and `lib` — which take their `lib` from
            # `import <nixpkgs>` — are deliberately left to `modpack-catalogue`
            # and the prep checks, which exercise the same code through the
            # flake. The module is the part that was actually broken, and the
            # part a consumer cannot work around.
            nonflake-entry =
              let
                nf = import ./default.nix;

                # `nixpkgs.lib.nixosSystem` directly rather than this flake's
                # `eval-config` helper: the helper injects its own `package`
                # `mkDefault`, which would collide with the one `default.nix`
                # supplies — two `mkDefault`s at one priority. That is also
                # exactly the path a real consumer takes.
                evaluated = nixpkgs.lib.nixosSystem {
                  system = pkgs.stdenv.hostPlatform.system;
                  modules = [
                    nf.nixosModules.default
                    {
                      # Unfree is already on in `pkgs`; passing it as an
                      # externally created instance also avoids NixOS's
                      # "configures nixpkgs with an externally created instance"
                      # assertion, which is what a real non-flake config does.
                      nixpkgs.pkgs = pkgs;
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/disk/by-label/nixos";
                        fsType = "ext4";
                      };
                      system.stateVersion = "25.05";
                      services.project-zomboid-servers = {
                        enable = true;
                        dataDir = "/var/lib/project-zomboid";
                        servers.plain = { };
                      };
                    }
                  ];
                };

                cfg = evaluated.config.services.project-zomboid-servers;
                services = evaluated.config.systemd.services;
                sockets = evaluated.config.systemd.sockets;
                sc = services.project-zomboid-plain.serviceConfig or { };

                rawAssertions = evaluated.config.assertions or [ ];
                assertions = if builtins.isList rawAssertions then rawAssertions else lib.attrValues rawAssertions;
                # A LIST, because these get `++`-ed into the `problems` list below —
                # so it has to be built with `optionals` (which yields a list),
                # not `optionalString` (which yields a string) and not
                # `concatMapStringsSep` (also a string).
                #
                # `lib.concatMap` over `optionalString` looks right and is wrong:
                # `concatMap` = `concat . map`, and `concat` wants each element to
                # be a list. With no failures `concat [ ]` never trips over it,
                # so the bug stays hidden until an assertion actually fails — the
                # exact moment the check most needs to explain itself.
                failedAssertions = lib.concatMap (a: lib.optionals (!a.assertion) [ a.message ]) (
                  lib.filter (a: !a.assertion) assertions
                );

                problems = lib.filter (s: s != null && s != "") (
                  [
                    # The attrset shape is the whole point: selecting
                    # `.nixosModules` off an `import` is impossible if the top
                    # level is a function.
                    (lib.optionalString (!builtins.isAttrs nf)
                      "default.nix does not evaluate to an attrset, so `(import (fetchTarball …)).nixosModules.default` cannot work"
                    )

                    (lib.optionalString (
                      !(nf ? nixosModules && nf ? modpacks && nf ? overlay && nf ? lib)
                    ) "default.nix is missing one of nixosModules / modpacks / overlay / lib")

                    # An overlay is `final: _prev:` — TWO arguments, because
                    # nixpkgs passes both. Applying one by hand
                    # (`(import ./overlay.nix) pkgs`) returns a partially
                    # applied function, which then fails much later and far
                    # from the cause ("expected a set but found a function"
                    # pointing at the overlay's own body).
                    #
                    # Asserted behaviourally rather than by inspecting the
                    # signature: `builtins.functionArgs` cannot see plain
                    # arguments at all (it reports `{}` for `x: x`), but
                    # over-applying is observable — applying to ONE argument
                    # must still yield a function.
                    (lib.optionalString (
                      !(builtins.isFunction nf.overlay) || !(builtins.isFunction (nf.overlay pkgs))
                    ) "overlay is not a two-argument (final, _prev) function")

                    (lib.optionalString (
                      !(builtins.isFunction nf.nixosModules.default)
                      || !(builtins.isFunction nf.nixosModules.project-zomboid-servers)
                    ) "nixosModules does not expose two module functions")

                    # `package` defaults to null in modules/options.nix because
                    # that file cannot reach the flake; default.nix is what
                    # fills it in for a non-flake consumer. Without this the
                    # module's own assertion fires and the consumer is told to
                    # set `package` — for a package this project ships.
                    (lib.optionalString (
                      cfg.package == null
                    ) "package was not supplied, so a non-flake consumer would have to set it by hand")

                    (lib.optionalString (!(services ? project-zomboid-plain)) "no project-zomboid-plain unit")
                    (lib.optionalString (!(sockets ? project-zomboid-plain)) "no console socket for plain")
                    (lib.optionalString (!(services ? project-zomboid-install)) "no project-zomboid-install unit")
                    (lib.optionalString (
                      !(lib.hasPrefix "/nix/store/" (sc.ExecStart or ""))
                    ) "ExecStart is not an absolute store path")
                  ]
                  ++ failedAssertions
                );
              in
              if problems == [ ] then
                pkgs.runCommand "pz-nonflake-entry-check" { } ''
                  echo "non-flake entry ok: default.nix is an attrset, supplies package, produces working units"
                  touch "$out"
                ''
              else
                throw ''
                  default.nix (the non-flake entry point) is broken:

                    ${lib.concatStringsSep "\n" (map (p: "  - ${p}") problems)}
                '';

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

            # ── A pinned Map= suppresses detection cleanly ──────────────────────
            # Regression guard for a real bug: the prep script passed its optional
            # Map= argument as `${map_override+...}`, and the `+` form expands
            # whenever the variable is SET — which an empty `map_override=""` is.
            # So pinning a map made the script pass a literal empty argument and
            # merge_ini.py aborted the whole start with a parse error. This is
            # only reachable with PZ_MAP_PINNED=1, which is why `prep-roundtrip`
            # (auto-detect) never saw it.
            map-pin-clean =
              let
                srv = "pinned";
                server = pz-lib.resolveServer self.modpacks srv (serverDefaults srv);
                prep = pz-prepare.mkPrepScript {
                  inherit server;
                  iniBase = pz-prepare.mkIniBase { inherit server; };
                  name = "pz-prep-pin";
                };
              in
              pkgs.runCommand "pz-map-pin-clean-check"
                {
                  nativeBuildInputs = [ pkgs.coreutils ];
                }
                ''
                  srv="${srv}"
                  root="$TMPDIR/pz"
                  data="$root/data"
                  mkdir -p "$data/$srv/Zomboid/Server"
                  export PZ_DATA_DIR="$data"
                  export PZ_SERVER_DIR="$root/server"
                  export PZ_SERVER_NAME="$srv"

                  # No maps installed at all, so detection would find nothing and
                  # leave map_override empty — the exact state that broke.
                  PZ_MAP_PINNED=1 ${prep}/bin/pz-prep-pin "Map=Rosewood, OR"

                  ini="$data/$srv/Zomboid/Server/$srv.ini"
                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  grep -qx 'Map=Rosewood, OR' "$ini" || fail "the pinned Map= did not land"
                  if grep -qx 'Map=$' "$ini"; then fail "an empty Map= was written"; fi
                  grep -qx 'UDPPort=16262' "$ini" || fail "the rest of the config did not land"

                  echo "map pin ok: pinning suppresses detection without an empty argument"
                  touch "$out"
                '';

            # ── Secrets never reach a store path ───────────────────────────────
            # The single most important check in this file.
            #
            # The regression it guards against is real and was measured: with a
            # secret in `settings`, the rendered base `.ini` was a `writeText`
            # store path at mode 444 containing e.g. `RCONPassword=hunter2` in
            # cleartext — readable by every local user and greppable out of
            # /nix/store. This asserts the value is nowhere in the store paths the
            # module generates, while the path of the secret file is.
            secrets-not-in-store =
              let
                srv = "secretive";
                secretPath = pkgs.writeText "pz-join-password" "hunter2-not-in-store";
                joinPath = pkgs.writeText "pz-join" "join-not-in-store";
                server = pz-lib.resolveServer self.modpacks srv (
                  (serverDefaults srv)
                  // {
                    secretFiles.RCONPassword = secretPath;
                    passwordFile = joinPath;
                  }
                );
                # The real artefacts, as store paths. Grepping the actual file in
                # /nix/store is the point of the check, so it must be the genuine
                # output rather than a copy — `builtins.readFile` cannot be used
                # here because it cannot realise a derivation during pure eval.
                iniBaseFile = pz-prepare.mkIniBase {
                  inherit server;
                  name = "${srv}.ini";
                };
                sandboxFile = pkgs.writeText "${srv}_SandboxVars.lua" (
                  pz-lib.renderSandbox { settings = server.sandbox; }
                );
              in
              pkgs.runCommand "pz-secrets-not-in-store-check"
                {
                  nativeBuildInputs = [ pkgs.coreutils ];
                  # Derivation values in the environment become their store paths,
                  # so the script greps the genuine world-readable files.
                  PZ_INI_BASE = iniBaseFile;
                  PZ_SANDBOX = sandboxFile;
                  PZ_RCON_SECRET = secretPath;
                }
                ''
                  ini="$PZ_INI_BASE"
                  sandbox="$PZ_SANDBOX"
                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  # The rendered files are the ones that end up mode 444 and
                  # world-readable in the store. Neither may contain a value.
                  if grep -q 'hunter2-not-in-store' "$ini"; then
                    fail "the RCON password reached the rendered .ini ($(stat -c %a "$ini"))"
                  fi
                  if grep -q 'join-not-in-store' "$ini"; then
                    fail "the join password reached the rendered .ini"
                  fi
                  if grep -q 'not-in-store' "$sandbox"; then
                    fail "a secret reached the rendered SandboxVars.lua"
                  fi

                  # The secret KEYS must be absent entirely: they are supplied at
                  # start by --secret-file, not rendered.
                  if grep -q '^RCONPassword=' "$ini"; then
                    fail "RCONPassword was rendered instead of deferred to a secret file"
                  fi
                  if grep -q '^Password=' "$ini"; then
                    fail "Password was rendered instead of deferred to a secret file"
                  fi

                  # And the arguments the prep script will use name the secret
                  # FILES, never their contents.
                  args="${pz-lib.secretFileArgs server}"
                  case "$args" in
                    *"$PZ_RCON_SECRET"*) ;;
                    *) fail "secretFileArgs does not reference the RCON secret's path" ;;
                  esac
                  case "$args" in
                    *hunter2*|*join-not-in-store*) fail "secretFileArgs leaked a secret VALUE" ;;
                  esac

                  echo "secrets ok: no secret value in any rendered store file"
                  touch "$out"
                '';

            # ── Spawn lua + soft-reset + Build 41 opt-in ────────────────────────
            # Everything in `prep-roundtrip` that is about the NEW surface:
            # the two spawn files, `--soft-reset`, and the fact that
            # `Whitelist=`/`Users=` are absent unless `compatibility.build41`.
            spawn-and-reset =
              let
                srv = "spawny";
                server = pz-lib.resolveServer self.modpacks srv (
                  (serverDefaults srv)
                  // {
                    whitelist = [
                      "alice"
                      "bob"
                    ];
                    admins = [ "carol" ];
                    spawn.points = [
                      {
                        pos = [
                          12067
                          6801
                          0
                        ];
                      }
                      {
                        pos = [
                          12068
                          6801
                          0
                        ];
                      }
                      {
                        pos = [
                          5000
                          5000
                          0
                        ];
                        profession = "engineer";
                      }
                      # A profession that is not a bare Lua identifier, to prove
                      # the key gets bracket-quoted rather than emitted as
                      # `"farm worker" = {`, which is a syntax error.
                      {
                        pos = [
                          10
                          10
                          0
                        ];
                        profession = "farm worker";
                      }
                    ];
                    spawn.regions = [
                      {
                        name = "Mod Spawn";
                        file = "media/maps/ModName/spawnpoints.lua";
                      }
                      {
                        name = "Quoted \"Region\"";
                        file = "media/maps/Other/spawnpoints.lua";
                      }
                    ];
                  }
                );
                prep = pz-prepare.mkPrepScript {
                  inherit server;
                  iniBase = pz-prepare.mkIniBase { inherit server; };
                  name = "pz-prep-spawn";
                };
                iniBase = pz-prepare.mkIniBase {
                  inherit server;
                  name = "${srv}.ini";
                };
                # The same server with the Build 41 opt-in, so the "absent by
                # default" assertion above is provably a choice and not a feature
                # that was quietly deleted.
                b41Server = pz-lib.resolveServer self.modpacks srv (
                  (serverDefaults srv)
                  // {
                    whitelist = server.whitelist;
                    admins = server.admins;
                    compatibility.build41 = true;
                  }
                );
                iniBaseB41 = pz-prepare.mkIniBase {
                  server = b41Server;
                  name = "${srv}-b41.ini";
                };
              in
              pkgs.runCommand "pz-spawn-and-reset-check"
                {
                  # lua is here to PARSE the generated files. Two real syntax
                  # errors shipped through this check before it existed, and
                  # neither was visible by reading the output:
                  #   * consecutive table entries joined by a newline instead of
                  #     a comma — `}` then `{` is not valid Lua;
                  #   * a quoted profession used as a key, `"farm worker" = {` —
                  #     Lua reads the string as a positional value and then finds
                  #     an `=` where it expects `,` or `}`.
                  # Both are silent to grep and fatal to the game.
                  nativeBuildInputs = [
                    pkgs.coreutils
                    pkgs.lua
                  ];
                  PZ_INI_B42 = iniBase;
                  PZ_INI_B41 = iniBaseB41;
                }
                ''
                  srv="${srv}"
                  root="$TMPDIR/pz"
                  data="$root/data"
                  mkdir -p "$data/$srv/Zomboid/Server"

                  cat > "$data/$srv/Zomboid/Server/$srv.ini" <<'SEED_INI'
                  Seed=keep-me
                  ResetID=999
                  ServerPlayerID=42
                  Password=existing-join-password
                  SEED_INI

                  export PZ_DATA_DIR="$data"
                  export PZ_SERVER_DIR="$root/server"
                  export PZ_SERVER_NAME="$srv"

                  ${prep}/bin/pz-prep-spawn
                  conf="$data/$srv/Zomboid/Server"
                  ini="$conf/$srv.ini"

                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  # ── Build 42 must NOT emit the dead keys ───────────────────
                  # Not merely absent by default: writing a config that lists an
                  # admin and a whitelist while doing nothing is worse than one
                  # that plainly does not.
                  if grep -q '^Whitelist=' "$ini"; then
                    fail "Whitelist= was written on a Build 42 server"
                  fi
                  if grep -q '^Users=' "$ini"; then
                    fail "Users= was written on a Build 42 server"
                  fi
                  if grep -q 'carol' "$PZ_INI_B42"; then
                    fail "an admin name leaked into the Build 42 config"
                  fi

                  # The opt-in still works, which is what makes the above a
                  # deliberate choice rather than a removed feature.
                  grep -q '^Whitelist=' "$PZ_INI_B41" \
                    || fail "compatibility.build41 did not re-enable Whitelist="
                  grep -q '^Whitelist=alice,bob' "$PZ_INI_B41" || fail "build41 Whitelist is malformed"
                  grep -q '^Users=carol' "$PZ_INI_B41" || fail "build41 Users is malformed"

                  # ── Spawn lua ──────────────────────────────────────────────
                  points="$conf/${srv}_spawnpoints.lua"
                  regions="$conf/${srv}_spawnregions.lua"
                  sandbox="$conf/${srv}_SandboxVars.lua"
                  [ -f "$points" ] || fail "no _spawnpoints.lua written"
                  [ -f "$regions" ] || fail "no _spawnregions.lua written"
                  grep -q 'function SpawnPoints()' "$points" || fail "spawnpoints is not a SpawnPoints function"
                  grep -q 'function SpawnRegions()' "$regions" || fail "spawnregions is not a SpawnRegions function"
                  grep -q 'posX = 12067, posY = 6801, posZ = 0' "$points" \
                    || fail "the spawn point coordinates were not rendered"
                  # Grouped by profession, with "unemployed" as the default — and emitted as a
                  # bare Lua identifier, the way PZ's own file does.
                  grep -q '^        unemployed = {' "$points" || fail "no unemployed spawn group"
                  grep -q '^        engineer = {' "$points" || fail "the engineer spawn group is missing"
                  # Consecutive entries must be comma-separated.
                  grep -q 'posZ = 0 },' "$points" || fail "spawn points are not comma-separated"
                  grep -q 'name = "Mod Spawn", file = "media/maps/ModName/spawnpoints.lua"' "$regions" \
                    || fail "the spawn region was not rendered"
                  # Lua string escaping in a rendered name.
                  grep -q 'name = "Quoted \\"Region\\""' "$regions" \
                    || fail "a quote in a region name was not escaped"

                  # ── Parse every generated Lua file ─────────────────────────
                  # Sandboxing the parser: these files come from Nix values a user
                  # controls, and loadfile executes nothing here, but running them
                  # at all is worth keeping as a parse only.
                  for f in "$points" "$regions" "$sandbox"; do
                    if ! lua -e "local fn, err = loadfile('$f'); if not fn then io.stderr:write(tostring(err)..'\\n'); os.exit(1) end"; then
                      fail "generated Lua is not valid: $f"
                    fi
                  done

                  # Profession keys: bare when a bare identifier works (matching
                  # PZ's own generated file), bracket-quoted when it does not.
                  grep -q '^        \["farm worker"\] = {' "$points" \
                    || fail "a profession name that is not an identifier was not bracket-quoted"
                  if grep -q '"engineer" = {' "$points"; then
                    fail "a plain profession name was emitted as a quoted key"
                  fi

                  # ── --soft-reset ────────────────────────────────────────────
                  # A second invocation with the flag must drop world identity
                  # while leaving config and the existing join password alone.
                  ${prep}/bin/pz-prep-spawn --soft-reset
                  grep -q '^Seed=' "$ini" && fail "--soft-reset did not clear Seed"
                  grep -q '^ResetID=' "$ini" && fail "--soft-reset did not clear ResetID"
                  grep -q '^ServerPlayerID=' "$ini" && fail "--soft-reset did not clear ServerPlayerID"
                  grep -qx 'Password=existing-join-password' "$ini" \
                    || fail "--soft-reset clobbered a key it does not own"
                  grep -qx 'UDPPort=16262' "$ini" || fail "--soft-reset dropped our own config"
                  [ -f "$points" ] || fail "--soft-reset removed the spawn file, which it must not"

                  echo "spawn+reset ok: dead keys absent, spawn lua rendered, soft-reset scoped"
                  touch "$out"
                '';

            # ── The secret guard actually guards ───────────────────────────────
            # A security control that is never exercised is a control that does not
            # work. This proves the assertion FIRES on every route a secret can
            # take into a store file — `settings`, `sandbox`, and each of a
            # modpack's two default sets — and, just as importantly, that a config
            # using `secretFiles` passes cleanly.
            #
            # An assertion failure does not throw; it lands in `config.assertions`
            # with `assertion = false` and the message. So this reads them back
            # rather than expecting evaluation to abort.
            secret-guard =
              pkgs.runCommand "pz-secret-guard-check"
                {
                  nativeBuildInputs = [ pkgs.coreutils ];
                  # Serialised eval results. `passAsFile` rather than
                  # `builtins.readFile`: the latter cannot realise a derivation
                  # during pure evaluation.
                  passAsFile = [
                    "leaksIni"
                    "leaksSandbox"
                    "leaksPackIni"
                    "leaksPackSandbox"
                    "clean"
                  ];
                  leaksIni = failedMessages {
                    servers.foo.settings.RCONPassword = "hunter2";
                  };
                  leaksSandbox = failedMessages { servers.foo.sandbox.DiscordToken = "bot"; };
                  leaksPackIni = failedMessages {
                    modpacks.bad.defaultSettings.WebhookAddress = "https://example/hook";
                    servers.foo.modpack = "bad";
                  };
                  leaksPackSandbox = failedMessages {
                    modpacks.bad.defaultSandbox.RCONPassword = "hunter2";
                    servers.foo.modpack = "bad";
                  };
                  clean = failedMessages {
                    servers.foo.secretFiles.RCONPassword = "/run/secrets/rcon";
                    servers.foo.passwordFile = "/run/secrets/join";
                  };
                }
                ''
                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  expect_guard() {
                    label="$1"; file="$2"
                    grep -q 'a secret is set in' "$file" \
                      || fail "$label did not trip the secret guard"
                  }

                  expect_clean() {
                    label="$1"; file="$2"
                    if [ -s "$file" ]; then
                      fail "$label should have evaluated cleanly, but reported: $(cat "$file")"
                    fi
                  }

                  expect_guard "a secret in settings"        "$leaksIniPath"
                  expect_guard "a secret in sandbox"         "$leaksSandboxPath"
                  expect_guard "a secret in a pack defaultSettings" "$leaksPackIniPath"
                  expect_guard "a secret in a pack defaultSandbox"  "$leaksPackSandboxPath"
                  expect_clean "a config using secretFiles"  "$cleanPath"

                  echo "secret guard ok: trips on every route, silent when secretFiles is used"
                  touch "$out"
                '';

            # ── Deterministic map ordering ──────────────────────────────────────
            # The property that makes `Map=` reproducible: the same mods in a
            # different on-disk order must produce byte-identical output, a
            # duplicate map name must be reported (and honoured under
            # --priority), and the base map must land last.
            map-ordering =
              pkgs.runCommand "pz-map-ordering-check"
                {
                  nativeBuildInputs = [
                    pkgs.python3
                    pkgs.coreutils
                  ];
                }
                ''
                  maps="${./scripts/pz_maps.py}"
                  work="$TMPDIR/maps"
                  fail() { echo "FAIL: $1" >&2; exit 1; }

                  # Two trees with identical CONTENT, created in opposite orders,
                  # so any dependence on directory iteration order shows up as a
                  # difference between the two runs.
                  mk() {
                    root="$1"; shift
                    for id in "$@"; do
                      mkdir -p "$root/wc/108600/$id/media/maps/Map$id"
                      touch "$root/wc/108600/$id/media/maps/Map$id/map_0.lotpack"
                    done
                  }
                  mk "$work/a" 500 100 400 200 300
                  mk "$work/b" 300 200 400 100 500

                  a="$(python3 "$maps" --workshop-root "$work/a/wc/108600" --base-map 'Muldraugh, KY' 2>/dev/null)"
                  b="$(python3 "$maps" --workshop-root "$work/b/wc/108600" --base-map 'Muldraugh, KY' 2>/dev/null)"
                  [ "$a" = "$b" ] || fail "map order depends on directory iteration order: '$a' vs '$b'"

                  # Numeric id order, base map last.
                  expected='Map100;Map200;Map300;Map400;Map500;Muldraugh, KY'
                  [ "$a" = "$expected" ] || fail "unexpected order: got '$a', want '$expected'"

                  # A directory that is not a map must not become a map name.
                  mkdir -p "$work/c/wc/108600/1/media/maps/JustDocs"
                  touch "$work/c/wc/108600/1/media/maps/JustDocs/README.md"
                  # NOT named `out`: that is the derivation's output path.
                  map_out="$(python3 "$maps" --workshop-root "$work/c/wc/108600" --base-map 'Muldraugh, KY' 2>/dev/null)"
                  [ "$map_out" = 'Muldraugh, KY' ] || fail "a non-map directory leaked into Map=: '$map_out'"

                  # A duplicate map name: reported, deterministic winner, and
                  # overridable. This is the conflict case the ordering exists for.
                  for id in 200 300; do
                    mkdir -p "$work/d/wc/108600/$id/media/maps/Shared, KY"
                    touch "$work/d/wc/108600/$id/media/maps/Shared, KY/map_0.lotpack"
                  done
                  err="$(python3 "$maps" --workshop-root "$work/d/wc/108600" --base-map 'Muldraugh, KY' 2>&1 >/dev/null || true)"
                  case "$err" in
                    *'is shipped by 2 mods'*) ;;
                    *) fail "a duplicate map name was not reported: $err" ;;
                  esac
                  def="$(python3 "$maps" --workshop-root "$work/d/wc/108600" --base-map 'Muldraugh, KY' 2>/dev/null)"
                  [ "$def" = 'Shared, KY;Muldraugh, KY' ] || fail "unexpected duplicate resolution: '$def'"
                  flipped="$(python3 "$maps" --workshop-root "$work/d/wc/108600" --base-map 'Muldraugh, KY' --priority 300 2>/dev/null)"
                  [ "$flipped" = 'Shared, KY;Muldraugh, KY' ] || fail "priority changed the set: '$flipped'"

                  # --strict must actually fail, or it is decoration.
                  if python3 "$maps" --workshop-root "$work/d/wc/108600" --base-map 'Muldraugh, KY' --strict >/dev/null 2>&1; then
                    fail "--strict did not fail on a duplicate map name"
                  fi

                  # A mod shipping the base map's own name shadows vanilla terrain
                  # and must be an ERROR, not a quiet pass.
                  mkdir -p "$work/e/wc/108600/7/media/maps/Muldraugh, KY"
                  touch "$work/e/wc/108600/7/media/maps/Muldraugh, KY/map_0.lotpack"
                  shadow="$(python3 "$maps" --workshop-root "$work/e/wc/108600" --base-map 'Muldraugh, KY' 2>&1 >/dev/null || true)"
                  case "$shadow" in
                    *ERROR*) ;;
                    *) fail "a mod shadowing the base map was not reported as an error" ;;
                  esac

                  echo "map ordering ok: deterministic, base map last, duplicates reported"
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
