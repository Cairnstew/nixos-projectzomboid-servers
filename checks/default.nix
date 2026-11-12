{
  pkgs,
  versions,
  lib,
  nixpkgsLib,
  self,
  modpackNames,
  pz-lib,
  pz-prepare,
  serverDefaults,
}:

let
  root = ../.;

  # Evaluate a NixOS configuration containing this module, per system.
  # lib/tests.nix exposes `{ eval, … }`, so take `.eval`.
  eval-config = (import ../lib/tests.nix { inherit lib; }).eval;

  # The messages of every assertion that FAILED for a given extra config, as
  # one string. A failing assertion does not abort evaluation — it is collected
  # in `config.assertions` with `assertion = false` and read back here — so this
  # is how a check can assert that a guard trips.
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
          web = extra.web or { };
          manage = extra.manage or { };
        };
      };
    in
    lib.concatStringsSep "\n---\n" (
      map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions)
    );

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
            updateSchedule = "daily";
            servers = {
              alpha = {
                modpack = "vanilla-plus";
                defaultPort = 16261;
                udpPort = 16262;
                openFirewall = true;
                settings.PVP = false;
                # Scheduled uptime + idle shutdown: both timers and the
                # root oneshot must exist, and the RCON assertion must be
                # satisfied by a real secret.
                rconPort = 27017;
                secretFiles.RCONPassword = "/run/secrets/pz-rcon";
                schedule.start = [ "*-*-* 22:00:00" ];
                idleStop = {
                  enable = true;
                  timeout = "15m";
                };
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
      timers = evaluated.config.systemd.timers;
      firewallUdp = lib.sort (a: b: a < b) (
        lib.toList (evaluated.config.networking.firewall.allowedUDPPorts or [ ])
      );
      firewallTcp = lib.sort (a: b: a < b) (
        lib.toList (evaluated.config.networking.firewall.allowedTCPPorts or [ ])
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
          # Locale: without a UTF-8 locale the JVM encodes filenames as
          # ASCII and aborts on a mod folder with a non-ASCII name.
          (lib.optionalString (
            !hasEnv unit "LC_ALL=C.UTF-8"
          ) "${unit} has no LC_ALL=C.UTF-8 — a non-ASCII mod folder would fail to load")
        ]
      ) (lib.attrNames cfg.servers);

      # Scheduled start and idle stop are new branches: assert the timers
      # exist, target the right units, and carry the configured values.
      scheduleFailures = [
        (lib.optionalString (timers ? project-zomboid-alpha-start == false) "no start timer for alpha")
        (lib.optionalString (
          timers ? project-zomboid-alpha-start
          && (timers.project-zomboid-alpha-start.timerConfig.Unit or "") != "project-zomboid-alpha.service"
        ) "alpha start timer does not target the server unit")
        (lib.optionalString (
          timers ? project-zomboid-alpha-start
          &&
            lib.toList (timers.project-zomboid-alpha-start.timerConfig.OnCalendar or [ ]) != [
              "*-*-* 22:00:00"
            ]
        ) "alpha start timer did not keep the configured OnCalendar")
        (lib.optionalString (
          services ? project-zomboid-alpha-idle == false
        ) "no idle-stop service for alpha")
        (lib.optionalString (timers ? project-zomboid-alpha-idle == false) "no idle-stop timer for alpha")
        (lib.optionalString (
          services ? project-zomboid-alpha-idle
          && !(storePath (services.project-zomboid-alpha-idle.serviceConfig.ExecStart or ""))
        ) "alpha idle-stop ExecStart is not a store path")
        (lib.optionalString (
          services ? project-zomboid-alpha-idle
          && !(lib.hasInfix "--timeout 15m" (
            services.project-zomboid-alpha-idle.serviceConfig.ExecStart or ""
          ))
        ) "alpha idle-stop did not receive the configured timeout")
      ];

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
        # The boot install and the scheduled updater share one unit.
        # The updater is root only for systemctl; the downloader must
        # stay as cfg.user or it leaves root-owned files behind.
        (lib.optionalString (
          services ? project-zomboid-install
          && (services.project-zomboid-install.serviceConfig.User or "") != cfg.user
        ) "the install unit does not run as cfg.user (${cfg.user})")
        (lib.optionalString (
          services ? project-zomboid-update == false
        ) "no project-zomboid-update unit despite updateSchedule")
        (lib.optionalString (
          services ? project-zomboid-update
          && (services.project-zomboid-update.serviceConfig.User or "") != "root"
        ) "the scheduled updater is not root (it needs systemctl try-restart)")
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
        # RCON is plaintext TCP and is loopback-only for the dashboard
        # and idle-stop. It must never be opened by merely setting
        # `rconPort`; only `openRconFirewall` may opt in.
        (lib.optionalString (firewallTcp != [ ])
          "firewall opened TCP ports by default: ${lib.concatStringsSep ", " firewallTcp} (neither openRconFirewall nor web.openFirewall was set)"
        )
        (lib.optionalString (
          !(cfg.modpacks ? vanilla-plus) || !(cfg.modpacks ? survival-hard)
        ) "the catalogue was not merged into modpacks")
        # The dedicated install and the prep step must both be pointed at
        # the SAME explicit Workshop directory, or map detection and the
        # download disagree about what is installed.
        (lib.optionalString (
          !hasEnv "project-zomboid-install" "PZ_WORKSHOP_DIR=${cfg.workshopDir}"
        ) "the install unit does not carry PZ_WORKSHOP_DIR=${cfg.workshopDir}")
        (lib.optionalString (
          !hasEnv "project-zomboid-alpha" "PZ_WORKSHOP_DIR=${cfg.workshopDir}"
        ) "a server unit does not carry PZ_WORKSHOP_DIR=${cfg.workshopDir}")
      ];

      # ── Fourth scenario: an explicit workshopDir ────────────────────
      # The option must actually reach the units; asserting only the
      # default would pass with the value hard-coded in Nix.
      workshopEval = eval-config {
        inherit pkgs;
        config.services.project-zomboid-servers = {
          enable = true;
          dataDir = "/var/lib/project-zomboid";
          workshopDir = "/mnt/pz-workshop/steamapps/workshop/content/108600";
          modpacks = self.modpacks;
          servers.only = {
            modpack = "vanilla-plus";
            defaultPort = 16261;
            udpPort = 16262;
          };
        };
      };

      workshopServices = workshopEval.config.systemd.services;
      workshopCfg = workshopEval.config.services.project-zomboid-servers;
      workshopEnv = workshopServices.project-zomboid-install.serviceConfig.Environment or [ ];
      workshopHasEnv =
        unit: prefix:
        builtins.any (e: lib.hasPrefix prefix e) (
          workshopServices.${unit}.serviceConfig.Environment or [ ]
        );
      workshopFailures = [
        (lib.optionalString (
          workshopCfg.workshopDir != "/mnt/pz-workshop/steamapps/workshop/content/108600"
        ) "workshopDir option did not evaluate to the configured path")
        (lib.optionalString (
          !(builtins.elem "PZ_WORKSHOP_DIR=/mnt/pz-workshop/steamapps/workshop/content/108600" workshopEnv)
        ) "the install unit did not receive the configured workshopDir")
        (lib.optionalString (
          !workshopHasEnv "project-zomboid-only" "PZ_WORKSHOP_DIR=/mnt/pz-workshop/steamapps/workshop/content/108600"
        ) "the server unit did not receive the configured workshopDir")
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
        # The ttyd unit is a control plane: it must not inherit sudo on
        # PATH, and it must keep the sandbox directives that stop a ttyd
        # or shim bug from reaching the rest of the host.
        (lib.optionalString (lib.any (p: (p.pname or "") == "sudo") (
          webSvcs.project-zomboid-socket-server-web.path or [ ]
        )) "the ttyd unit still has sudo on PATH")
        (lib.optionalString (
          (webSvcs.project-zomboid-socket-server-web.serviceConfig.NoNewPrivileges or false) != true
        ) "the ttyd unit lost NoNewPrivileges")
        (lib.optionalString (
          (webSvcs.project-zomboid-socket-server-web.serviceConfig.ProtectSystem or "") != "strict"
        ) "the ttyd unit does not use ProtectSystem=strict")
      ];

      # ── Third scenario: a pack driving the in-game Host button ───────
      # `enable = false` on the SERVER, on purpose: the main use of a
      # client host is a machine with NO dedicated server, so the pack
      # must still render while no unit exists. A separate evaluation for
      # the same reason as the web scenario — a branch no check evaluates
      # is a branch that rots, and "renders nothing, silently" is exactly
      # how this would fail.
      clientEval = eval-config {
        inherit pkgs;
        config.services.project-zomboid-servers = {
          # The DEDICATED half is OFF. This is the whole point: a client
          # host must render without an install unit, a steamcmd run, a
          # service user — or even the master switch.
          enable = false;
          dataDir = "/var/lib/project-zomboid";
          modpacks = self.modpacks;
          servers.viewpoint = {
            enable = false;
            modpack = "viewpoint";
            clientHost.enable = true;
            # The preset must render from the same pack list, without a
            # dedicated server existing. The name is left empty on
            # purpose: it has to fall back to the attribute name.
            clientHost.preset.enable = true;
            # The firewall must be opened from the CLIENT half: this eval
            # has `enable = false`, so the server-level `openFirewall` is
            # not even in play.
            clientHost.openFirewall = true;
          };
        };
      };

      clientCfg = clientEval.config.services.project-zomboid-servers;
      clientHosts = clientCfg.clientHosts or { };
      clientSvcs = clientEval.config.systemd.services;
      oneHost = clientHosts.viewpoint or null;

      clientFailures = [
        (lib.optionalString (
          clientHosts ? viewpoint == false
        ) "clientHost.enable produced no clientHosts entry")
        # The whole point of resolving separately: a client host must not
        # drag a dedicated server into existence.
        (lib.optionalString (
          clientSvcs ? project-zomboid-viewpoint
        ) "a server with enable = false still produced a dedicated server unit")
        # A client host is config, not a dedicated server. With the
        # master switch off there must be no install unit to run
        # steamcmd and no service user to own an install.
        (lib.optionalString (
          clientSvcs ? project-zomboid-install
        ) "a client-host-only config produced project-zomboid-install (steamcmd)")
        (lib.optionalString (
          clientEval.config.users.users ? project-zomboid
        ) "a client-host-only config created the project-zomboid service user")
        (lib.optionalString (
          oneHost == null || oneHost.serverName != "servertest"
        ) "clientHosts.viewpoint.serverName is not the default \"servertest\"")
        (lib.optionalString (
          oneHost == null || !(lib.hasPrefix "/nix/store/" (toString (oneHost.prepare or "")))
        ) "clientHosts.viewpoint.prepare is not a store path")
        (lib.optionalString (
          oneHost == null || !(lib.hasPrefix "/nix/store/" (toString (oneHost.iniFile or "")))
        ) "clientHosts.viewpoint.iniFile is not a store path")
        (lib.optionalString (
          oneHost == null || builtins.length (oneHost.workshopItems or [ ]) < 100
        ) "the viewpoint pack's Workshop list did not reach clientHosts")
        (lib.optionalString (
          oneHost == null || builtins.length (oneHost.mods or [ ]) < 100
        ) "the viewpoint pack's Mods list did not reach clientHosts")
        # The preset is a client-only list of the SAME mods. It must be
        # rendered even with the dedicated half off, and its name must
        # fall back to the server attribute.
        (lib.optionalString (
          oneHost == null || (oneHost.presetName or null) != "viewpoint"
        ) "clientHost.preset did not resolve to the server attribute name")
        (lib.optionalString (
          oneHost == null || !(lib.hasPrefix "/nix/store/" (toString (oneHost.presetFile or "")))
        ) "clientHost.preset produced no store path")
        # `clientHost.openFirewall` has to open BOTH UDP ports. The
        # server-level `openFirewall` never sees this server (it is
        # filtered to enabled ones), so without the client wiring the
        # option is a silent no-op — exactly the failure mode this check
        # exists for.
        (lib.optionalString (
          !(lib.all (p: builtins.elem p (clientEval.config.networking.firewall.allowedUDPPorts or [ ])) [
            versions.defaultPort
            versions.defaultUdpPort
          ])
        ) "clientHost.openFirewall did not open both UDP ports")
      ];

      failures = lib.filter (s: s != null && s != "") (
        perServer
        ++ staticFailures
        ++ assertionFailures
        ++ scheduleFailures
        ++ webFailures
        ++ clientFailures
        ++ workshopFailures
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

in
{
  launcher =
    let
      pkg = pkgs.callPackage (root + "/pkgs/project-zomboid-server") { };
    in
    pkgs.runCommand "pz-launcher-check"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
        LAUNCHER = pkg;
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        # PZ's Java resolves `Zomboid` from `user.home`, which the JVM
        # takes from the passwd entry, NOT from $HOME. Without this
        # flag every server on a host shares <dataDir>/Zomboid (the
        # service user's home) and ignores the per-server
        # <dataDir>/<name>/Zomboid that the prep script writes. That
        # produced a fresh default world with RCON off on the first
        # Viewpoint start (2026-11-12).
        grep -qF -- '-Duser.home=$pz_home' "$LAUNCHER/bin/project-zomboid-server" \
          || fail "the launcher does not pin -Duser.home to PZ_SERVER_HOME"
        grep -qF -- 'PZ_SERVER_HOME' "$LAUNCHER/bin/project-zomboid-server" \
          || fail "the launcher does not accept PZ_SERVER_HOME"
        echo "launcher ok: -Duser.home is pinned to PZ_SERVER_HOME"
        touch "$out"
      '';

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

  # ── pz-manage: RCON framing and backup roundtrip, offline ──────────
  # The dashboard's two risky pieces are a hand-written Source RCON
  # client and a tar-based backup/restore. Both are exercised here
  # with a fake server and a temp world, so a protocol or path change
  # fails CI rather than a live server.
  manage =
    pkgs.runCommand "pz-manage-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.coreutils
          pkgs.gnutar
          pkgs.zstd
        ];
        MANAGE = root + "/modules/manage";
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }
        cp -r "$MANAGE" "$TMPDIR/manage"
        chmod -R u+w "$TMPDIR/manage"
        cd "$TMPDIR/manage"

        # ── Source RCON: auth, the empty pre-auth reply, multi-packet
        python3 - <<'PY' || fail "RCON client assertions failed"
        import socket, struct, threading, time
        from rcon import RconClient, RconError, parse_players

        def recv_exact(sock, size):
            data = b""
            while len(data) < size:
                chunk = sock.recv(size - len(data))
                if not chunk:
                    raise EOFError
                data += chunk
            return data

        def recv_packet(sock):
            (size,) = struct.unpack("<i", recv_exact(sock, 4))
            payload = recv_exact(sock, size)
            req_id, kind = struct.unpack("<ii", payload[:8])
            return req_id, kind, payload[8:-2].decode()

        def send_packet(sock, req_id, kind, body):
            payload = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
            sock.sendall(struct.pack("<i", len(payload)) + payload)

        def serve(port, password):
            listener = socket.socket()
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", port))
            listener.listen(1)
            conn, _ = listener.accept()
            req_id, kind, body = recv_packet(conn)
            assert kind == 3
            if body != password:
                send_packet(conn, -1, 2, "")
            else:
                send_packet(conn, req_id, 0, "")   # PZ's empty pre-auth reply
                send_packet(conn, req_id, 2, "")   # AUTH_RESPONSE
                while True:
                    try:
                        req_id, kind, body = recv_packet(conn)
                    except EOFError:
                        break
                    if kind != 2:
                        continue
                    if body == "big":
                        send_packet(conn, req_id, 0, "x" * 4086)
                        send_packet(conn, req_id, 0, "y" * 10)
                    else:
                        send_packet(conn, req_id, 0, "Players connected (2):\n-A\n-B\n")
            conn.close()
            listener.close()

        thread = threading.Thread(target=serve, args=(27099, "pw"), daemon=True)
        thread.start()
        time.sleep(0.2)
        with RconClient("127.0.0.1", 27099, "pw") as client:
            reply = client.command("players")
            assert reply == "Players connected (2):\n-A\n-B\n", repr(reply)
            big = client.command("big")
            assert len(big) == 4096 and big[0] == "x" and big[-1] == "y", len(big)

        parsed = parse_players("Players connected (2):\n-A\n-B\n")
        assert parsed["players"] == ["A", "B"] and parsed["count"] == 2
        assert not parsed["ambiguous"]
        assert parse_players("Players connected (1):\n-x\n-Alice\n")["ambiguous"]
        print("RCON framing ok")
        PY

        # ── Idle-stop duration and ini parsing ──────────────────────
        python3 - <<'PY' || fail "idle-stop parsing assertions failed"
        import time
        from pathlib import Path
        from idle_stop import parse_duration, read_ini
        import server as manage_server

        assert parse_duration("90s") == 90
        assert parse_duration("30m") == 1800
        assert parse_duration("2h") == 7200
        assert parse_duration("1d") == 86400
        for bad in ("", "30", "m30", "1h30m", "-5m"):
            try:
                parse_duration(bad)
            except ValueError:
                pass
            else:
                raise AssertionError(f"parse_duration accepted {bad!r}")

        # CSRF: the legacy POST route has no custom header, so it is
        # guarded by Sec-Fetch-Site. Absent header = legacy client,
        # same-origin/none = browser navigation, anything else = reject.
        assert manage_server.same_origin_only({})
        assert manage_server.same_origin_only({"Sec-Fetch-Site": "same-origin"})
        assert manage_server.same_origin_only({"Sec-Fetch-Site": "none"})
        assert not manage_server.same_origin_only({"Sec-Fetch-Site": "cross-site"})
        assert not manage_server.same_origin_only({"Sec-Fetch-Site": "same-site"})

        ini = Path("idle-test.ini")
        ini.write_text("RCONPort=27017\nRCONPassword=a=b=c\n# comment\n", encoding="utf-8")
        values = read_ini(ini)
        assert values["RCONPort"] == "27017"
        assert values["RCONPassword"] == "a=b=c"

        # The dashboard reads the idle timestamp the root timer writes.
        state = Path("idle-state")
        state.write_text(str(int(time.time()) - 60), encoding="ascii")
        info = manage_server.idle_status({
            "name": "t",
            "idleStop": {"enable": True, "timeout": "30m"},
            "idleStateFile": str(state),
        })
        assert info["enabled"] and info["timeoutSeconds"] == 1800
        assert info["emptySince"] and info["stopAt"] == info["emptySince"] + 1800
        assert not manage_server.idle_status({
            "idleStop": {"enable": False},
        })["enabled"]
        missing = manage_server.idle_status({
            "idleStop": {"enable": True, "timeout": "30m"},
            "idleStateFile": "does-not-exist",
        })
        assert missing["emptySince"] is None and missing["stopAt"] is None

        # `systemctl list-timers --output=json` reports `next` in
        # microseconds since the epoch; no human date to parse.
        manage_server.systemctl = lambda *args, **kwargs: (
            0,
            '[{"unit": "t.timer", "next": 1794550800000000}]',
        )
        assert manage_server.timer_next_elapse("t.timer") == 1794550800
        manage_server.systemctl = lambda *args, **kwargs: (0, "[]")
        assert manage_server.timer_next_elapse("t.timer") is None
        print("idle-stop parsing ok")
        PY

        # ── Backup / prune / restore roundtrip ─────────────────────
        root="$TMPDIR/pz"
        mkdir -p "$root/home/Zomboid/Server" \
                 "$root/home/Zomboid/Saves/Multiplayer/test" \
                 "$root/home/Zomboid/db" \
                 "$root/backups/test"
        printf 'Seed=keep\n' > "$root/home/Zomboid/Server/test.ini"
        printf 'world\n' > "$root/home/Zomboid/Saves/Multiplayer/test/map.bin"
        printf 'db\n' > "$root/home/Zomboid/db/test.db"

        cat > "$root/config.json" <<'JSON'
        {
          "servers": [
            {
              "name": "test",
              "unit": "project-zomboid-test",
              "home": "HOME",
              "backupDirectory": "BACKUPS",
              "backupKeep": 2,
              "rconPort": 0,
              "rconPasswordFile": null
            }
          ]
        }
        JSON
        sed -i "s|HOME|$root/home|; s|BACKUPS|$root/backups/test|" "$root/config.json"

        python3 backups.py --config "$root/config.json" run --server test \
          || fail "backup run failed"
        archive="$(ls "$root"/backups/test/*.tar.zst | head -1)"
        [ -n "$archive" ] || fail "no archive was created"
        [ "$(stat -c %a "$archive")" = 640 ] \
          || fail "backup archive mode is $(stat -c %a "$archive"), expected 640"
        tar --zstd -tf "$archive" | grep -qx 'Zomboid/Saves/Multiplayer/test/map.bin' \
          || fail "the world was not in the archive"
        if tar --zstd -tf "$archive" | grep -q '\.local/share/Steam'; then
          fail "the Steam token directory was archived"
        fi

        printf 'changed\n' > "$root/home/Zomboid/Saves/Multiplayer/test/map.bin"
        python3 backups.py --config "$root/config.json" restore \
          --server test --archive "$(basename "$archive")" \
          || fail "restore failed"
        grep -qx 'world' "$root/home/Zomboid/Saves/Multiplayer/test/map.bin" \
          || fail "restore did not put the original file back"

        # A crafted archive (the game user can write the backup
        # directory) must not be able to write outside the world.
        raw="$root/evil.tar"
        python3 - "$raw" <<'PY'
        import io, sys, tarfile
        with tarfile.open(sys.argv[1], "w") as tf:
            data = b"escaped\n"
            info = tarfile.TarInfo("../escape")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        PY
        evil="$root/backups/test/test-20260101-000000.tar.zst"
        zstd -q -f "$raw" -o "$evil"
        if python3 backups.py --config "$root/config.json" restore \
             --server test --archive "$(basename "$evil")" >/dev/null 2>&1; then
          fail "restore accepted an archive with an unsafe member"
        fi
        [ ! -e "$root/home/escape" ] && [ ! -e "$root/escape" ] \
          || fail "an unsafe archive member escaped the server home"

        # Prune: three archives with keep=2 leaves two.
        for _ in 1 2 3; do
          python3 backups.py --config "$root/config.json" run --server test >/dev/null \
            || fail "backup run failed during prune test"
        done
        count="$(ls "$root"/backups/test/*.tar.zst | wc -l)"
        [ "$count" -le 2 ] || fail "retention kept $count archives, expected <= 2"

        echo "pz-manage ok: RCON framing, backup, prune and restore"
        touch "$out"
      '';

  # ── The Workshop helpers behave, offline ───────────────────────────
  # `expand` is a network tool, so only its PURE parts (child order,
  # Nix escaping) are exercised here while `emit` runs for real over
  # the injected catalogue. Nothing in `nix flake check` may hit the
  # network, or the check becomes a flaky test of Valve's uptime.
  pz-workshop-helper =
    pkgs.runCommand "pz-workshop-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.python3
        ];
        WORKSHOP = root + "/scripts/pz_workshop.py";
        CATALOGUE = pkgs.writeText "modpacks.json" (builtins.toJSON self.modpacks);
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        python3 - "$WORKSHOP" "$CATALOGUE" <<'PY' || fail "emit/expand assertions failed"
        import importlib.util, io, json, os, subprocess, sys

        workshop, catalogue = sys.argv[1], sys.argv[2]
        spec = importlib.util.spec_from_file_location("pz_workshop", workshop)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)

        # emit must reproduce every pack's item count AND order.
        packs = json.load(open(catalogue))
        for name, pack in packs.items():
            n = len(pack.get("workshopMods", []))
            env = dict(os.environ, PZ_MODPACKS_JSON=catalogue)
            out = subprocess.run(
                [sys.executable, workshop, "emit", name],
                capture_output=True, text=True, env=env,
            )
            if out.returncode != 0:
                raise SystemExit("emit " + name + " failed: " + out.stderr)
            urls = [l for l in out.stdout.splitlines() if l.startswith("https://")]
            if len(urls) != n:
                raise SystemExit("emit " + name + ": " + str(len(urls)) + " urls, expected " + str(n))
            for i, item in enumerate(pack.get("workshopMods", [])):
                if ("id=" + item["id"]) not in urls[i]:
                    raise SystemExit("emit " + name + ": order wrong at " + str(i))

        # expand: children come back in sortorder, not API order.
        m.post = lambda endpoint, params: {
            "result": 1,
            "collectiondetails": [{
                "result": 1,
                "publishedfileid": "9",
                "children": [
                    {"publishedfileid": "b", "sortorder": 1},
                    {"publishedfileid": "a", "sortorder": 0},
                ],
            }],
        }
        ids, _ = m.collection_children("9")
        if ids != ["a", "b"]:
            raise SystemExit("collection order: " + repr(ids))

        # A title carrying an interpolation MUST be escaped, or the
        # generated pack will not evaluate. Build the marker without
        # writing it literally, so this test itself stays Nix-safe.
        d = chr(36)
        rendered = m.render_pack("9", None, [("a", "A" + d + "{b}", None)], "108600", "p")
        if ("\\" + d) not in rendered:
            raise SystemExit("render_pack left an unescaped interpolation")

        # Description -> internal Mod ID parsing (the "resolve after
        # download" gap): HTML/bbcode must be stripped, the
        # `Mod ID:[/b] X` artifact handled, `MID:` accepted, and a
        # description that only mentions a dependency must not be
        # misread as declaring nothing for the item itself.
        parse = m.mod_ids_from_description
        samples = [
            ("<div>Mod ID: ZombieBuddy</div>", ["ZombieBuddy"]),
            ("[b]Mod ID:[/b] ZombieBuddy_Extensions", ["ZombieBuddy_Extensions"]),
            ("MID: Viewpoint", ["Viewpoint"]),
            ("Whatever description", []),
            ("Works with Mod ID: OtherMod<br>Mod ID: ThisMod",
             ["OtherMod", "ThisMod"]),
        ]
        for desc, want in samples:
            if parse(desc) != want:
                raise SystemExit("mod_ids_from_description: " + repr(parse(desc)) + " != " + repr(want))

        # render_pack prefills mods in item order, dedupes, keeps the
        # escaping, and flags an item whose description declared no id.
        rendered = m.render_pack(
            "9", None,
            [("a", "A", None), ("b", "B", None), ("c", "C no id", None)],
            "108600", "p",
            mods_by_id={"a": ["Alpha"], "b": ["Bravo", "Alpha"]},
        )
        if rendered.count('"Alpha"') != 1 or '"Bravo";' not in rendered:
            raise SystemExit("render_pack prefill/dedupe broken")
        if '  mods = [ ];' in rendered:
            raise SystemExit("render_pack lost the mods list")
        if "no `Mod ID:` in its description" not in rendered:
            raise SystemExit("render_pack missing the unresolved-item flag")

        # The Web API key: read from a FILE, and added to the request
        # only when the file yields one. An unreadable path must stay a
        # warning rather than an error, because every endpoint here
        # works anonymously and the key only buys a rate budget.
        import tempfile
        keyfile = tempfile.NamedTemporaryFile("w", suffix=".key", delete=False)
        # A single backslash: Nix indented strings pass \ through
        # literally, so Python is what reads this as a newline. The
        # surrounding spaces are the point — a real secret file has a
        # trailing newline and is stripped.
        keyfile.write("  SECRET123 \n")
        keyfile.close()

        os.environ.pop(m.API_KEY_FILE_ENV, None)
        if m.api_key() != "":
            raise SystemExit("api_key without the env var must be empty")

        os.environ[m.API_KEY_FILE_ENV] = keyfile.name
        if m.api_key() != "SECRET123":
            raise SystemExit("api_key did not read/strip the file")

        os.environ[m.API_KEY_FILE_ENV] = "/nonexistent/steam-key"
        if m.api_key() != "":
            raise SystemExit("an unreadable key file must fall back to anonymous")

        # The key must reach the REQUEST BODY. This has to drive the
        # real `post`, not a stubbed one: the injection lives inside
        # `post` itself, and an earlier assertion here has already
        # replaced `m.post` with a fake to test collection ordering —
        # so capture the pristine function at import time and observe
        # the encoded form through a stubbed `urlopen`.
        import io as _io
        import urllib.request as _urlreq

        # An earlier assertion here replaced `m.post` with a fake to
        # test collection ordering, so drive a FRESH module instance:
        # asserting against that stub would pass without exercising the
        # key injection this is meant to cover.
        spec2 = importlib.util.spec_from_file_location("pz_workshop_fresh", workshop)
        fresh = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(fresh)

        sent = {}
        class _FakeResp(_io.BytesIO):
            def __enter__(self):
                return self
            def __exit__(self, *_):
                return False
        real_urlopen = _urlreq.urlopen
        def fake_urlopen(req, timeout=None):
            sent["body"] = req.data.decode()
            return _FakeResp(json.dumps({"response": {}}).encode())
        _urlreq.urlopen = fake_urlopen
        try:
            # Point back at the real file: the assertion above left the
            # env var on the unreadable path on purpose.
            os.environ[fresh.API_KEY_FILE_ENV] = keyfile.name
            fresh.post("GetPublishedFileDetails/v1/", {"itemcount": 1})
            if "key=SECRET123" not in sent["body"]:
                raise SystemExit(
                    "keyed request body lacked the key: " + sent["body"]
                )
            os.environ.pop(fresh.API_KEY_FILE_ENV, None)
            sent.clear()
            fresh.post("GetPublishedFileDetails/v1/", {"itemcount": 1})
            if "key" in sent["body"]:
                raise SystemExit(
                    "an anonymous request must not send a key: " + sent["body"]
                )
        finally:
            _urlreq.urlopen = real_urlopen
        os.unlink(keyfile.name)

        # result=9 is Steam's RATE LIMIT and looks exactly like a
        # missing item (empty title, no fields). It must be reported as
        # throttling, or `expand` tells the user to verify mods that are
        # alive — so the diagnostic is asserted, not just hoped for.
        m.post = lambda endpoint, params: {
            "publishedfiledetails": [
                {"publishedfileid": "1", "result": 9},
                {"publishedfileid": "2", "result": 9},
                {"publishedfileid": "3", "result": 1, "title": "Real",
                 "description": "Mod ID: Real", "file_type": 0,
                 "consumer_app_id": 108600},
            ],
        }
        err = io.StringIO()
        real_stderr, sys.stderr = sys.stderr, err
        try:
            got = m.published_details(["1", "2", "3"])
        finally:
            sys.stderr = real_stderr
        if got["3"]["title"] != "Real":
            raise SystemExit("a good item was lost alongside throttled ones")
        if m.warn_throttled.__doc__ is None:
            raise SystemExit("warn_throttled lost its docstring")
        said = err.getvalue()
        if "RATE LIMIT" not in said or "9" not in said:
            raise SystemExit("a throttled item was not reported: " + repr(said))
        if "- 1" not in said or "- 2" not in said:
            raise SystemExit("the throttled ids were not named: " + repr(said))
        # A genuinely absent item must NOT be called a rate limit.
        err = io.StringIO()
        real_stderr, sys.stderr = sys.stderr, err
        try:
            m.warn_throttled([])
        finally:
            sys.stderr = real_stderr
        if err.getvalue():
            raise SystemExit("warn_throttled spoke with nothing throttled")

        print("pz-workshop assertions ok")
        PY

        echo "pz-workshop ok: emit matches the catalogue; expand order, escaping and Mod-ID parsing hold"
        touch "$out"
      '';

  # The client downloader's PLAN is offline (no steamcmd, no network),
  # so the item count, the default local-mods target and the unknown-
  # pack error are all asserted here.
  pz-client-mods-plan =
    pkgs.runCommand "pz-client-mods-plan-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.python3
        ];
        CLIENT = root + "/scripts/pz_client_mods.py";
        CATALOGUE = pkgs.writeText "modpacks.json" (builtins.toJSON self.modpacks);
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        python3 - "$CLIENT" "$CATALOGUE" <<'PY' || fail "client plan assertions failed"
        import json, os, subprocess, sys, tempfile

        client, catalogue = sys.argv[1], sys.argv[2]
        packs = json.load(open(catalogue))
        env = dict(os.environ, PZ_MODPACKS_JSON=catalogue)
        for name, pack in packs.items():
            n = len(pack.get("workshopMods", []))
            out = subprocess.run(
                [sys.executable, client, "--json", name],
                capture_output=True, text=True, env=env,
            )
            if out.returncode != 0:
                raise SystemExit("plan " + name + " failed: " + out.stderr)
            if n == 0:
                # A pack with no Workshop items is a no-op, so only the
                # exit status above is meaningful for it.
                continue
            plan = json.loads(out.stdout)
            if plan["mode"] != "local-mods":
                raise SystemExit(name + ": the default target is not local mods")
            if len(plan["items"]) != n:
                raise SystemExit(
                    name + ": planned " + str(len(plan["items"])) + " items, expected " + str(n)
                )
            if plan["target"].rstrip("/").split("/")[-1] != "mods":
                raise SystemExit(name + ": local-mods target is not the mods folder")

        bad = subprocess.run(
            [sys.executable, client, "--json", "no-such-pack"],
            capture_output=True, text=True, env=env,
        )
        if bad.returncode == 0:
            raise SystemExit("plan accepted an unknown pack")

        # Workshop content is untrusted: a mod.info id becomes a
        # directory name, and --force deletes that directory. It must
        # never escape the target.
        import importlib.util
        spec = importlib.util.spec_from_file_location("pz_client_mods", client)
        pcm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pcm)
        assert pcm.safe_item_id("2625441155")
        assert not pcm.safe_item_id("../../etc")
        assert pcm.safe_mod_id("BritasArmorPack")
        assert not pcm.safe_mod_id("../../.config/autostart")
        with tempfile.TemporaryDirectory() as tmp:
            item = os.path.join(tmp, "item", "Mod")
            os.makedirs(item)
            with open(os.path.join(item, "mod.info"), "w", encoding="utf-8") as fh:
                fh.write("id=../../escape\n")
            target = os.path.join(tmp, "mods")
            os.makedirs(target)
            pcm.install_local(os.path.join(tmp, "item"), target, "123", True, [])
            if os.path.exists(os.path.join(tmp, "escape")):
                raise SystemExit("a mod.info id escaped the target directory")

        print("client plan ok")
        PY

        echo "pz-client-mods plan ok: counts, default target and unknown-pack all behave"
        touch "$out"
      '';

  # ── The prune helper is pure filesystem work, so it runs for real ──
  # Workshop mode must delete undeclared NUMERIC entries and leave
  # everything else; links mode must delete only symlinks — a real
  # directory a user placed by hand is the one thing that must never
  # go; --dry-run must change nothing.
  pz-prune =
    pkgs.runCommand "pz-prune-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.python3
        ];
        PRUNE = root + "/scripts/pz_prune.py";
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }
        root="$TMPDIR/workshop"
        mkdir -p "$root/111" "$root/222" "$root/333" "$root/notanid"
        touch "$root/111/x"

        python3 "$PRUNE" workshop --root "$root" --keep 111 --keep 222 >/dev/null 2>&1 \
          || fail "workshop prune returned non-zero"
        [ -d "$root/111" ] || fail "kept item 111 was removed"
        [ -d "$root/222" ] || fail "kept item 222 was removed"
        [ ! -e "$root/333" ] || fail "undeclared item 333 survived a shared-root prune"
        [ -d "$root/notanid" ] || fail "a non-numeric entry was removed"

        mkdir -p "$root/444"
        python3 "$PRUNE" workshop --root "$root" --keep 111 --dry-run >/dev/null 2>&1 \
          || fail "workshop --dry-run returned non-zero"
        [ -d "$root/444" ] || fail "--dry-run removed a directory"

        links="$TMPDIR/links"
        mkdir -p "$links"
        ln -s "$TMPDIR" "$links/555"
        ln -s "$TMPDIR" "$links/666"
        mkdir -p "$links/real"
        python3 "$PRUNE" links --root "$links" --keep 555 >/dev/null 2>&1 \
          || fail "links prune returned non-zero"
        [ -L "$links/555" ] || fail "a kept symlink was removed"
        [ ! -L "$links/666" ] || fail "an undeclared symlink survived a links prune"
        [ -d "$links/real" ] || fail "links mode removed a real directory"

        echo "pz-prune ok: workshop and links modes keep only what is declared"
        touch "$out"
      '';

  module-eval = moduleEvalResult;

  # ── The client-host prepare writes CONFIG ONLY ─────────────────────
  # The whole point of the split: this script must never acquire a
  # steamcmd or Steam-library path, and must write only under
  # `$PZ_CLIENT_ZOMBOID/Server/`. A regression here is silent in
  # production (the files still appear), so it is checked structurally
  # AND by running the real script.
  #
  # It also proves the merge semantics the Host screen depends on:
  # a re-run re-applies the declared keys while keeping the world
  # identity (Seed) and any key the module does not own.
  client-host-prepare =
    let
      evaluated = eval-config {
        inherit pkgs;
        config.services.project-zomboid-servers = {
          enable = false;
          modpacks = self.modpacks;
          servers.viewpoint = {
            enable = false;
            modpack = "viewpoint";
            clientHost.enable = true;
            clientHost.preset.enable = true;
          };
        };
      };
      host = evaluated.config.services.project-zomboid-servers.clientHosts.viewpoint;
    in
    pkgs.runCommand "pz-client-host-prepare-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
        ];
        PREPARE = lib.getExe host.prepare;
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        # Structural: the generated script must not name a Steam path
        # or a mod-delivery mechanism. Comments in the script are fine,
        # so the patterns are the ones that would actually act.
        forbidden='steamcmd|steamapps|libraryfolders|PZ_SERVER_DIR|PZ_CLIENT_WORKSHOP|PZ_LINK_STEAM_WORKSHOP|Zomboid/mods'
        if grep -Eq "$forbidden" "$PREPARE"; then
          fail "the client-host prepare script references a Steam/mod path: $(grep -En "$forbidden" "$PREPARE" | head -5)"
        fi

        zomboid="$TMPDIR/client/Zomboid"
        export PZ_CLIENT_ZOMBOID="$zomboid"

        "$PREPARE"
        ini="$zomboid/Server/servertest.ini"
        sandbox="$zomboid/Server/servertest_SandboxVars.lua"

        [ -f "$ini" ] || fail "no servertest.ini written"
        [ -f "$sandbox" ] || fail "no servertest_SandboxVars.lua written"
        # Build 42 has no `SelfManagedMods` key — it is absent from the
        # 42.21 jar and from the 144-key .ini the server writes back.
        # Rendering it would be a silent no-op, so it must not appear.
        ! grep -q '^SelfManagedMods=' "$ini" || fail "SelfManagedMods was written for Build 42"
        grep -q '^WorkshopItems=.\+' "$ini" || fail "WorkshopItems did not reach the client ini"
        grep -q '^Mods=.\+' "$ini" || fail "Mods did not reach the client ini"
        # Build 42 splits Mods= on ';' only. A comma-joined list is
        # read as one mod id (the whole line becomes a missing
        # "required mod"), so no mods load and Map= entries are skipped.
        ! grep -q '^Mods=[^=]*,' "$ini" || fail "Mods= is comma separated; Build 42 would load nothing"

        # Only the declared config may be created. The Server/ files
        # plus the one opt-in preset file under Lua/. In particular no
        # `mods/`, no Workshop link farm, and no Saves directory.
        top="$(find "$zomboid" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')"
        [ "$top" = "Lua Server " ] || fail "client prepare created more than Lua/ and Server/: $top"
        lua_files="$(find "$zomboid/Lua" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')"
        [ "$lua_files" = "pz_modlist_settings.cfg " ] || fail "client prepare wrote unexpected files under Lua/: $lua_files"
        [ ! -e "$zomboid/mods" ] || fail "client prepare created ~/Zomboid/mods"

        # The preset is a client-side copy of the same ordered mods
        # list. It is a SEPARATE file from Server/<name>.ini, because
        # the Host flow's Mods= does not enable the client's own mods
        # outside a hosted world.
        preset="$zomboid/Lua/pz_modlist_settings.cfg"
        head -n1 "$preset" | grep -qx '!fav!:' || fail "favourite line is not first in the preset file"
        grep -q '^viewpoint:' "$preset" || fail "managed preset line missing"
        [ "$(grep -c '^viewpoint:' "$preset")" -eq 1 ] || fail "managed preset line is duplicated"
        mods_n="$(sed -n 's/^Mods=//p' "$ini" | tr ';' '\n' | grep -c .)"
        preset_n="$(sed -n 's/^viewpoint://p' "$preset" | tr ';' '\n' | grep -c .)"
        [ "$mods_n" -eq "$preset_n" ] || fail "preset has $preset_n ids but Mods= has $mods_n"
        grep -q 'ZombieBuddy;' "$preset" || fail "preset is missing ZombieBuddy"
        printf 'mine:ZombieBuddy;\n' >> "$preset"
        sed -i 's/^!fav!:/!fav!:ZombieBuddy;/' "$preset"

        # The game's Host screen rewrites the file and drops every key
        # it does not know. A second run must re-apply the declared
        # keys, keep the world identity and leave foreign keys alone —
        # and must not resurrect a key Build 42 does not read.
        managed_before="$(sed -n 's/^viewpoint://p' "$preset")"
        printf 'Seed=keep-this\n' >> "$ini"
        printf 'SomeUnknownKey=1\n' >> "$ini"
        "$PREPARE"
        grep -qx 'Seed=keep-this' "$ini" || fail "a re-run reset the world identity"
        grep -qx 'SomeUnknownKey=1' "$ini" || fail "a re-run dropped a key it does not own"
        grep -q '^Mods=.\+' "$ini" || fail "a re-run lost Mods"
        ! grep -q '^SelfManagedMods=' "$ini" || fail "a re-run wrote SelfManagedMods for Build 42"

        # The preset merge must be just as non-destructive: the
        # player's own preset and favourites survive, and the managed
        # line is replaced rather than appended a second time.
        grep -qx 'mine:ZombieBuddy;' "$preset" || fail "a re-run dropped the player's own preset"
        grep -qx '!fav!:ZombieBuddy;' "$preset" || fail "a re-run dropped favourites"
        [ "$(grep -c '^viewpoint:' "$preset")" -eq 1 ] || fail "a re-run duplicated the managed preset"
        managed_after="$(sed -n 's/^viewpoint://p' "$preset")"
        [ "$managed_before" = "$managed_after" ] || fail "the managed preset changed on a re-run"
        cp "$preset" "$TMPDIR/preset.before"
        "$PREPARE"
        cmp -s "$preset" "$TMPDIR/preset.before" || fail "the preset file is not idempotent"

        echo "client-host prepare ok: config + one merged preset only, no mod paths, no B42 SelfManagedMods, world identity/foreign keys/player presets preserved on re-run"
        touch "$out"
      '';

  # ── The client mod fetch is isolated from Steam ─────────────────────
  # `home.installMods` is deprecated but still ships, so its steamcmd
  # must run with its own HOME. If it ever inherits the user's, steamcmd
  # can discover and rewrite `~/.local/share/Steam/.../libraryfolders.vdf`
  # — the failure that broke Steam's staging on 2026-10-07.
  pz-client-mods-isolation =
    pkgs.runCommand "pz-client-mods-isolation-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.python3
        ];
        CLIENT = root + "/scripts/pz_client_mods.py";
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        python3 - "$CLIENT" <<'PY' || fail "client isolation assertions failed"
        import importlib.util, os, stat, subprocess, sys, tempfile

        client = sys.argv[1]
        spec = importlib.util.spec_from_file_location("pz_client_mods", client)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)

        # The default isolated HOME is under the cache, never under a
        # Steam root. Point `~` at a temp dir so the test is hermetic.
        tmp = tempfile.mkdtemp()
        os.environ.pop("PZ_CLIENT_MODS_HOME", None)
        os.environ["HOME"] = tmp
        home = m.client_mods_home()
        want = os.path.join(tmp, ".cache", "pz-client-mods", "home")
        if home != want:
            raise SystemExit("isolated HOME is " + home + ", expected " + want)

        # steamcmd must RECEIVE that HOME. A fake records it.
        fake = os.path.join(tmp, "fake-steamcmd")
        out = os.path.join(tmp, "seen-home")
        with open(fake, "w") as fh:
            fh.write("#!/bin/sh\nprintf '%s\\n' \"$HOME\" > " + out + "\n")
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)

        m.steamcmd_download(fake, os.path.join(tmp, "stage"), "108600", ["1"], None, home)
        seen = open(out).read().strip()
        if seen != home:
            raise SystemExit("steamcmd ran with HOME=" + seen + ", expected " + home)
        if "Steam" in seen or ".steam" in seen:
            raise SystemExit("steamcmd HOME points into a Steam tree: " + seen)

        # The Steam-library target mode is gone, not merely defaulted
        # off: there is no code path that can write into a library.
        src = open(client).read()
        for needle in ("--steam-library", "discover_library", "--workshop-helper"):
            if needle in src:
                raise SystemExit("client downloader still offers " + needle)

        print("client isolation ok: isolated HOME, steamcmd receives it, no library mode")
        PY

        touch "$out"
      '';

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
        OPTIONS_NIX = root + "/modules/options.nix";
        OPTIONS_DOC = root + "/docs/options.md";
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
      nf = import (root + "/default.nix");

      # `nixpkgs.lib.nixosSystem` directly rather than this flake's
      # `eval-config` helper: the helper injects its own `package`
      # `mkDefault`, which would collide with the one `default.nix`
      # supplies — two `mkDefault`s at one priority. That is also
      # exactly the path a real consumer takes.
      evaluated = nixpkgsLib.nixosSystem {
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
            !(nf ? nixosModules && nf ? homeModules && nf ? modpacks && nf ? overlay && nf ? lib)
          ) "default.nix is missing one of nixosModules / homeModules / modpacks / overlay / lib")

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

          (lib.optionalString (
            !(builtins.isFunction nf.homeModules.default)
            || !(builtins.isFunction nf.homeModules.project-zomboid-servers)
          ) "homeModules does not expose two module functions")

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
          # A non-Workshop mod: the prep script must symlink it into
          # Zomboid/mods, and `Mods=` must gain its folder name.
          localMods = {
            TestLocalMod = root + "/modpacks/vanilla-plus.nix";
          };
        }
      );
      # prune = true so a dropped workshop item is REMOVED from the
      # server's link farm rather than merely left dangling.
      prep = pz-prepare.mkPrepScript {
        inherit server;
        iniBase = pz-prepare.mkIniBase { inherit server; };
        name = "pz-prep-roundtrip";
        prune = true;
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
        export PZ_WORKSHOP_DIR="$server_root/steamapps/workshop/content/108600"
        export PZ_SERVER_NAME="$srv"

        # Runtime overrides, exactly as the runner passes them.
        ${prep}/bin/pz-prep-roundtrip \
          "DefaultPort=16299" \
          "Map=Rosewood, OR"

        ini="$data/$srv/Zomboid/Server/$srv.ini"
        sandbox="$data/$srv/Zomboid/Server/${srv}_SandboxVars.lua"

        fail() { echo "FAIL: $1" >&2; exit 1; }

        # The merged .ini contains RCON/join passwords after
        # --secret-file; it must not be group- or world-readable.
        [ "$(stat -c %a "$ini")" = 600 ] \
          || fail "merged .ini mode is $(stat -c %a "$ini"), expected 600"

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
        # The comma is optional: a nested table after this key makes it
        # a non-final entry, and Lua allows (here, requires) the comma.
        grep -qE '^ +Zombies = [0-9]+,?$' "$sandbox" || fail "the modpack's sandbox vars did not land"

        # ── Workshop symlinks ───────────────────────────────────────
        link="$data/$srv/Zomboid/Workshop/content/108600/2625441155"
        [ -L "$link" ] || fail "no symlink for a downloaded Workshop item"
        [ -e "$link" ] || fail "the Workshop symlink dangles"
        # prune is on: a symlink for an undownloaded UNDECLARED mod
        # must be removed outright, not left dangling.
        [ ! -L "$stale" ] || fail "prune left a stale symlink behind for a dropped mod"

        # ── Local (non-Workshop) mods ────────────────────────────────
        local_link="$data/$srv/Zomboid/mods/TestLocalMod"
        [ -L "$local_link" ] || fail "a declared localMod was not symlinked into Zomboid/mods"
        grep -q '^Mods=.*TestLocalMod' "$ini" || fail "a localMod key was not added to Mods="

        echo "prep roundtrip ok: world identity preserved, config merged, sandbox written, mods linked, prune kept only the declared set"
        touch "$out"
      '';

  # ── Renderer guards ───────────────────────────────────────────────
  # Four inputs produce a silently broken server rather than an eval
  # error, so all are asserted here:
  #   * a newline in a value — the .ini has no escape for one, and Lua
  #     forbids a raw newline inside a short string;
  #   * a `settings` key that duplicates a module-owned line — notably
  #     `Map`, which the prep script overwrites at every start, so the
  #     user's value would be ignored with no warning at all;
  #   * a Build 41 key that B42 no longer reads, or a B42 key that only
  #     works inside a nested table set flat — PZ ignores unknown keys,
  #     so the server starts cleanly and the setting does nothing;
  #   * `rconPort` without an `RCONPassword` — PZ starts no listener,
  #     and the resolver reports it instead of leaving it silent.
  render-guards =
    let
      base = {
        defaultPort = 16261;
        udpPort = 16262;
        rconPort = 0;
        public = true;
        publicName = "guard";
        maxPlayers = 32;
        open = true;
      };
      ini =
        extra:
        pz-lib.renderIniLines {
          settings = base // extra;
          mods = [ ];
          workshopItems = [ ];
        };
      sandbox = settings: pz-lib.renderSandbox { inherit settings; };
      # The resolver is where a USER-supplied reserved key is caught.
      # (The renderer catches pack defaults and direct callers for the
      # keys it does not own; `UPnP` is rendered by the module itself
      # and `SelfManagedMods` only exists in Build 41, so only the
      # resolver can tell a user's value from its own.)
      resolved =
        extra:
        pz-lib.resolveServer self.modpacks "guard" ((serverDefaults "guard") // { settings = extra; });
      # Same fixture but merging arbitrary top-level options, for the
      # resolver-level warnings (`rconPort` without an RCON password).
      resolvedWith =
        extra: pz-lib.resolveServer self.modpacks "guard" ((serverDefaults "guard") // extra);
      # `deepSeq`, not plain `tryEval`: the guard throws while the
      # returned list is being constructed, and a shallow tryEval would
      # stop at the cons cell and report success either way.
      evaluates = x: (builtins.tryEval (builtins.deepSeq x x)).success;
      # Shell fragments rather than whole `if` blocks: the check stays
      # readable and the failure message is impossible to forget.
      expectFail = msg: x: if evaluates x then "fail ${lib.escapeShellArg msg}" else ":";
      expectPass = msg: x: if evaluates x then ":" else "fail ${lib.escapeShellArg msg}";
      expectTrue = msg: cond: if cond then ":" else "fail ${lib.escapeShellArg msg}";
      luaFile = pkgs.writeText "guard-SandboxVars.lua" (
        pz-lib.renderSandbox {
          settings = {
            Note = "a\nb\"c\\d";
          };
        }
      );
      nestedFile = pkgs.writeText "guard-nested.lua" (
        pz-lib.renderSandbox {
          settings = {
            Zombies = 5;
            "ZombieConfig.PopulationStartMultiplier" = 1.5;
          };
        }
      );
    in
    pkgs.runCommand "pz-render-guards-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
        ];
        LUA_FILE = luaFile;
        NESTED_FILE = nestedFile;
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }

        # A newline in an .ini value must fail evaluation...
        ${expectFail "a newline in an .ini value was accepted" (ini {
          ServerWelcomeMessage = "a\nb";
        })}

        # ...and a reserved key must fail, naming its owning option —
        # through the resolver (the user's own settings)...
        ${expectFail "settings.MaxPlayers was accepted although maxPlayers owns it" (resolved {
          MaxPlayers = 64;
        })}
        ${expectFail "settings.Map was accepted although the prep script overwrites Map= at start"
          (resolved {
            Map = "Foo";
          })
        }
        ${expectFail "settings.UPnP was accepted although upnp owns it" (resolved {
          UPnP = false;
        })}
        ${expectFail "settings.SelfManagedMods was accepted although selfManagedMods owns it" (resolved {
          SelfManagedMods = false;
        })}

        # ...and through the renderer (a modpack's defaultSettings or a
        # direct caller).
        ${expectFail "a pack default of MaxPlayers reached the renderer" (ini {
          MaxPlayers = 64;
        })}

        # ...while a free-form key still renders normally.
        ${expectPass "a free-form settings key was rejected" (resolved {
          PVP = true;
        })}

        # `SelfManagedMods` only exists in Build 41 (it is absent from
        # the 42.21 jar and from the .ini the server writes back), so
        # a Build 42 target must not emit it — while a Build 41 target
        # still gets it.
        ${expectTrue "a Build 42 ini wrote SelfManagedMods" (
          !(lib.hasInfix "SelfManagedMods" (
            lib.concatStringsSep "\n" (
              pz-lib.renderIniLines {
                settings = (resolvedWith { }).settings;
                mods = [ ];
                workshopItems = [ ];
              }
            )
          ))
        )}
        ${expectTrue "a Build 41 ini dropped SelfManagedMods" (
          lib.hasInfix "SelfManagedMods=true" (
            lib.concatStringsSep "\n" (
              pz-lib.renderIniLines {
                settings = (resolvedWith { }).settings;
                mods = [ ];
                workshopItems = [ ];
                legacyBuild41 = true;
              }
            )
          )
        )}

        # RCON is started only when the port is non-zero AND the
        # password is non-empty, so a port without a password is a
        # silent no-op the resolver must report.
        ${expectTrue "rconPort without an RCONPassword produced no warning" (
          (resolvedWith { rconPort = 27017; }).warnings != [ ]
        )}
        ${expectTrue "rconPort with an RCONPassword still warned" (
          (resolvedWith {
            rconPort = 27017;
            secretFiles.RCONPassword = "/dev/null";
          }).warnings == [ ]
        )}
        ${expectTrue "rconPort = 0 produced a warning" ((resolvedWith { }).warnings == [ ])}

        # Build 41 keys that B42 silently ignores must fail instead.
        # The moved-section cases...
        ${expectFail "the B41 ini key MinutesPerPage was accepted" (ini {
          MinutesPerPage = 2.0;
        })}
        ${expectFail "the B41 ini key HoursForLootRespawn was accepted" (ini {
          HoursForLootRespawn = 0;
        })}
        # ...the renames...
        ${expectFail "the B41 ini key DisableSafehouseWhenPlayerConnected was accepted" (ini {
          DisableSafehouseWhenPlayerConnected = false;
        })}
        ${expectFail "the B41 ini key DiscordChannel was accepted" (ini {
          DiscordChannel = "pz";
        })}
        # ...and the B41 sandbox enums that became *LootNew floats, plus
        # the two known-bad spellings that were in the packs.
        ${expectFail "the B41 sandbox key FoodLoot was accepted" (sandbox {
          FoodLoot = 2;
        })}
        ${expectFail "the B41 sandbox key WeaponLoot was accepted" (sandbox {
          WeaponLoot = 2;
        })}
        ${expectFail "the invented sandbox key MeleeWeaponLootNew was accepted" (sandbox {
          MeleeWeaponLootNew = 0.6;
        })}
        ${expectFail "the invented sandbox key ZombieDamage was accepted" (sandbox {
          ZombieDamage = 2;
        })}

        # The B42 spellings still render.
        ${expectPass "the B42 sandbox key FoodLootNew was rejected" (sandbox {
          FoodLootNew = 0.4;
        })}
        ${expectPass "the B42 sandbox key WeaponLootNew was rejected" (sandbox {
          WeaponLootNew = 0.6;
        })}

        # B42 nested-table keys must be dotted; the flat form is an
        # unknown option. `Farming` is the one ambiguous name: flat is
        # the farming-speed enum, dotted is the XP multiplier.
        ${expectFail "the flat ZombieConfig key PopulationStartMultiplier was accepted" (sandbox {
          PopulationStartMultiplier = 1.5;
        })}
        ${expectFail "the flat ZombieLore key Speed was accepted" (sandbox {
          Speed = 2;
        })}
        ${expectPass "the dotted ZombieConfig key was rejected" (sandbox {
          "ZombieConfig.PopulationStartMultiplier" = 1.5;
        })}
        ${expectPass "the flat Farming enum was rejected" (sandbox {
          Farming = 3;
        })}
        ${expectPass "the dotted MultiplierConfig.Farming key was rejected" (sandbox {
          "MultiplierConfig.Farming" = 1.2;
        })}

        # ...and the dotted form actually renders a Lua table.
        grep -qF '    ZombieConfig = {' "$NESTED_FILE" \
          || fail "a dotted sandbox key did not render as a nested table"
        grep -qE 'PopulationStartMultiplier = 1\.5' "$NESTED_FILE" \
          || fail "the nested value did not land in ZombieConfig"

        # The version header must be present: without it PZ treats the
        # file as version 0 and migrates values (e.g. DayLength 8 -> 14).
        grep -qx '    VERSION = 6,' "$LUA_FILE" \
          || fail "SandboxVars.lua has no VERSION header — PZ would migrate the values"

        # A Lua string escapes newlines, quotes and backslashes rather
        # than emitting a raw newline (which is a syntax error).
        grep -qF 'Note = "a\nb\"c\\d"' "$LUA_FILE" \
          || fail "a SandboxVars string was not escaped for Lua"

        echo "render guards ok: newline, reserved-key, stale-B41 and flat-nested inputs fail; SelfManagedMods is B41-only; RCON without a password warns; free-form, B42 and dotted keys still work"
        touch "$out"
      '';

  # ── The install step is verified, not fire-and-forget ─────────────
  # Guards the failure mode this feature exists to fix: a Workshop
  # item steamcmd answers `Access Denied` for was silently skipped and
  # the servers started with mods missing. PZ_STEAMCMD points the
  # script at a stub, so the whole flow — batch download, per-item
  # verification, loud failure naming the missing mod, prune only
  # AFTER success — runs offline.
  install-verify-prune =
    let
      install = pz-prepare.mkInstallScript {
        steamcmd = pkgs.steamcmd;
        workshopItems = [
          "111"
          "222"
        ];
        prune = true;
        itemTitles = {
          "111" = "Item One";
          "222" = "Item Two";
        };
        name = "pz-install-check";
      };
    in
    pkgs.runCommand "pz-install-verify-prune-check"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
        ];
        INSTALL = install;
      }
      ''
        fail() { echo "FAIL: $1" >&2; exit 1; }
        root="$TMPDIR/pz"
        data="$root/data"
        server="$root/server"
        # DELIBERATELY outside serverDir: this is the option's whole
        # purpose. steamcmd is told the library root that contains it.
        workshop="$root/workshop-lib/steamapps/workshop/content/108600"
        mkdir -p "$data" "$workshop/999"
        touch "$workshop/999/stale"

        # A stub steamcmd: `+app_update` is a no-op, and each requested
        # `+workshop_download_item <appid> <id>` creates the content
        # directory steamcmd would have created — unless the id is in
        # FAKE_REFUSE (the Access-Denied case). Every argument is logged
        # so the force_install_dir actually passed can be asserted.
        cat > "$TMPDIR/fake-steamcmd" <<'FAKE'
        #!/bin/sh
        printf '%s\n' "$@" >> "$FAKE_LOG"
        state=0
        for arg in "$@"; do
          case "$state" in
            0) [ "$arg" = "+workshop_download_item" ] && state=1 ;;
            1) state=2 ;;
            2) id="$arg"
               case " ''${FAKE_REFUSE:-} " in
                 *" $id "*) : ;;
                 *) mkdir -p "$PZ_WORKSHOP_DIR/$id"
                    touch "$PZ_WORKSHOP_DIR/$id/contents.txt" ;;
               esac
               state=0 ;;
          esac
        done
        exit 0
        FAKE
        chmod +x "$TMPDIR/fake-steamcmd"

        export PZ_DATA_DIR="$data"
        export PZ_SERVER_DIR="$server"
        export PZ_WORKSHOP_DIR="$workshop"
        export PZ_STEAMCMD="$TMPDIR/fake-steamcmd"
        export FAKE_LOG="$TMPDIR/steamcmd.log"
        export FAKE_REFUSE=""

        PZ_PRUNE=1 "$INSTALL/bin/pz-install-check" \
          || fail "a successful install was reported as failed"

        [ -f "$workshop/111/contents.txt" ] || fail "item 111 was not installed"
        [ -f "$workshop/222/contents.txt" ] || fail "item 222 was not installed"
        [ ! -e "$workshop/999" ] || fail "prune left an undeclared item in the shared cache"

        # The configurable directory must reach steamcmd as the library
        # root that contains it, not as a second app install.
        grep -qx -- "$root/workshop-lib" "$FAKE_LOG" \
          || fail "steamcmd was not given the workshopDir's library root: $(tr '\n' ' ' < "$FAKE_LOG")"
        grep -qx -- "$server" "$FAKE_LOG" \
          || fail "steamcmd was not given serverDir for app_update: $(tr '\n' ' ' < "$FAKE_LOG")"

        # Now refuse 222 (as a gated item would), recreate a stale
        # 999, and assert the install FAILS, names the item, and does
        # NOT prune while a download is broken.
        rm -rf "$workshop/222"
        mkdir -p "$workshop/999"
        export FAKE_REFUSE="222"
        if msg="$(PZ_PRUNE=1 "$INSTALL/bin/pz-install-check" 2>&1)"; then
          fail "install reported success with a Workshop item missing"
        fi
        echo "$msg" | grep -q '222' || fail "the failure message did not name the missing item"
        echo "$msg" | grep -q 'Item Two' || fail "the failure message did not use the mod title"
        [ -d "$workshop/999" ] || fail "prune ran while a download was failing — content was deleted"

        # Lenient mode: the same missing item is logged and SKIPPED,
        # the install succeeds, the server would boot — and prune is
        # still withheld while something is missing.
        if msg="$(PZ_PRUNE=1 PZ_FAIL_ON_MISSING=0 "$INSTALL/bin/pz-install-check" 2>&1)"; then
          :
        else
          fail "lenient install failed instead of skipping"
        fi
        echo "$msg" | grep -qi 'skipping' || fail "lenient mode did not log the skip"
        echo "$msg" | grep -q '222' || fail "lenient mode did not name the skipped item"
        [ -d "$workshop/999" ] || fail "lenient+prune removed an item while something was missing"
        [ -f "$workshop/111/contents.txt" ] || fail "lenient mode lost a mod that did download"

        echo "install verify ok: failures are loud and named, prune runs only after every item verifies, lenient logs and skips"
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
        export PZ_WORKSHOP_DIR="$root/server/steamapps/workshop/content/108600"
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
        export PZ_WORKSHOP_DIR="$root/server/steamapps/workshop/content/108600"
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
          "idleNoRcon"
          "webNoPassword"
          "tcpClash"
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
        idleNoRcon = failedMessages {
          servers.foo.idleStop.enable = true;
        };
        webNoPassword = failedMessages {
          web.enable = true;
          web.username = "pz";
          servers.foo = { };
        };
        tcpClash = failedMessages {
          servers.a = {
            defaultPort = 16261;
            udpPort = 16262;
            rconPort = 27017;
            secretFiles.RCONPassword = "/run/secrets/rcon-a";
          };
          servers.b = {
            defaultPort = 16271;
            udpPort = 16272;
            rconPort = 27017;
            secretFiles.RCONPassword = "/run/secrets/rcon-b";
          };
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
        grep -q 'idleStop needs RCON' "$idleNoRconPath" \
          || fail "idleStop without RCON did not trip the guard"
        grep -q 'web.username is set but' "$webNoPasswordPath" \
          || fail "web.username without web.passwordFile did not trip the auth guard"
        grep -q 'two TCP services claim the same port' "$tcpClashPath" \
          || fail "two servers on the same rconPort did not trip the TCP collision guard"
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
        maps="${root + "/scripts/pz_maps.py"}"
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
}
