# checks/vm.nix
#
# A small NixOS VM test for the systemd side of the module.
#
# The evaluation checks in `checks/default.nix` can assert what the unit
# *definitions* contain, but not that systemd accepts them, that the sandbox
# directives leave the prep script able to write the data directory, or that the
# unit actually reaches `active`. A stub `package` makes that possible without
# downloading the game: the unit's ExecStart is replaced by a tiny launcher, and
# everything around it (ExecStartPre, the console socket, tmpfiles, the user and
# group) is the real thing.
#
# The stub deliberately does NOT use steam-run/bwrap, so this cannot catch a
# regression in the FHS shim. It is a smoke test, not a replacement for a real
# host boot.
{
  pkgs,
  ...
}:

let
  # A child that stands in for the JVM. It never reads stdin, and its store path
  # ends in `pz-stub-jvm` so the test can find it by name — `exec -a` is not an
  # option here, because nixpkgs' coreutils is a multi-call binary and refuses a
  # foreign argv[0] with "coreutils: unknown program".
  stubChild = pkgs.writeShellScript "pz-stub-jvm" ''
    while :; do
      ${pkgs.coreutils}/bin/sleep 3600
    done
  '';

  # `writeShellApplication` sets `meta.mainProgram`, which is what
  # `lib.getExe cfg.package` looks up. The loop keeps the unit in `active`
  # without touching the console FIFO.
  #
  # The child is what makes this a faithful stand-in for the real thing: the
  # launcher execs `steam-run`, whose bwrap stays the main PID while
  # `ProjectZomboid64` runs as its child, and neither reads the console FIFO
  # during mod loading. A stop therefore has no working graceful path — only
  # escalation — which is precisely the case that used to orphan the JVM. The
  # `pz-stub-jvm` name in the child's path is what the test greps for afterwards.
  #
  # The real package carries these two app ids from versions.json and the
  # module reads them without `or`; the stub has to provide them too or
  # evaluation fails before the VM is even built.
  stubPackage =
    pkgs.writeShellApplication {
      name = "project-zomboid-server-stub";
      text = ''
        echo "stub project-zomboid server: $*"
        ${stubChild} &
        while :; do
          ${pkgs.coreutils}/bin/sleep 3600
        done
      '';
    }
    // {
      serverAppId = "380870";
      steamAppId = "108600";
    };
in
pkgs.testers.runNixOSTest {
  name = "project-zomboid-unit-hardening";

  nodes.machine =
    { ... }:
    {
      imports = [ ../modules/project-zomboid-servers.nix ];

      system.stateVersion = "24.05";

      services.project-zomboid-servers = {
        enable = true;
        package = stubPackage;
        dataDir = "/var/lib/project-zomboid";
        # The stub is not a real install, so there is nothing to update at boot;
        # leaving this on would make the server unit Require a steamcmd run.
        updateOnStart = false;
        manage.enable = true;
        backup.enable = true;

        servers.demo = {
          description = "VM hardening smoke test";
          name = "demo";
          defaultPort = 16261;
          udpPort = 16262;
          autoStart = true;
          # Idle shutdown is the other unit that has to read something outside
          # its own sandbox. RCON is not reachable in this VM, which is fine:
          # the point is that the oneshot gets far enough to try.
          rconPort = 27017;
          secretFiles.RCONPassword = "/etc/pz-rcon";
          idleStop = {
            enable = true;
            timeout = "1m";
          };
          # The stop test below has to reach the escalation branch, and ExecStop
          # already spends 15s on `save`/`quit`. 20s keeps the test short while
          # still exercising a real timeout.
          extraServiceConfig = {
            TimeoutStopSec = "20s";
          };
        };
      };

      # A stand-in for the agenix secret. It has to be readable by the SERVICE
      # USER, not just by root: the prep script merges `RCONPassword=` into the
      # .ini as that user, so a root-only 0400 secret (agenix's default) breaks
      # the start. The idle oneshot still gets it through LoadCredential, which
      # is what the test exercises.
      environment.etc."pz-rcon".text = "vm-test-rcon-password\n";
    };

  testScript = ''
    import datetime

    machine.wait_for_unit("project-zomboid-demo.service")

    def prop(unit, name):
        return machine.succeed(f"systemctl show -p {name} --value {unit}").strip()

    def expect(unit, name, value):
        actual = prop(unit, name)
        assert actual == value, f"{unit} {name}: expected {value!r}, got {actual!r}"

    # The game unit is the one whose sandbox has to coexist with steam-run's
    # bwrap user namespace. These directives must be present and must not have
    # stopped the prep script or the launcher from running.
    expect("project-zomboid-demo.service", "NoNewPrivileges", "yes")
    expect("project-zomboid-demo.service", "ProtectSystem", "strict")
    expect("project-zomboid-demo.service", "ProtectHome", "yes")
    expect("project-zomboid-demo.service", "LockPersonality", "yes")
    expect("project-zomboid-demo.service", "ProtectKernelTunables", "yes")
    expect("project-zomboid-demo.service", "RestrictSUIDSGID", "yes")

    # ReadWritePaths is what lets the prep script create Zomboid/Server under
    # ProtectSystem=strict. Check the generated ini exists rather than trusting
    # the option alone.
    machine.succeed("test -s /var/lib/project-zomboid/demo/Zomboid/Server/demo.ini")

    # The dashboard and backup units run unprivileged and have no reason to
    # hold a capability; both accept their sandbox at boot.
    machine.wait_for_unit("project-zomboid-manage.service")
    expect("project-zomboid-manage.service", "CapabilityBoundingSet", "")
    expect("project-zomboid-manage.service", "ProtectSystem", "strict")
    expect("project-zomboid-backup.service", "NoNewPrivileges", "yes")
    expect("project-zomboid-backup.service", "CapabilityBoundingSet", "")

    # ── The idle oneshot can actually read its inputs ─────────────────────
    # It used to read the `0600` rendered .ini as a capability-less root and
    # silently `return 0` when that failed, so the timer reported success once a
    # minute forever while the server stayed up. The port is now baked into the
    # unit and the password arrives as a systemd credential: if either input
    # were missing or unreadable the oneshot would exit non-zero and this start
    # would fail instead of logging the conservative "RCON unavailable" line.
    machine.succeed("systemctl start project-zomboid-demo-idle.service")
    idle_log = machine.succeed("journalctl -b -u project-zomboid-demo-idle.service")
    assert "RCON unavailable" in idle_log, idle_log

    # ── A stop during "mod load" must not orphan the JVM ──────────────────
    # The stub never reads its console FIFO, so ExecStop's `save`/`quit` reach
    # nobody — the same wall a real server hits until it has finished loading
    # mods. systemd can only escalate. With KillMode=process that escalation
    # reached the main PID (the bwrap wrapper) alone and left the JVM — the
    # child, `pz-stub-jvm` here — alive in the cgroup; the next start logged
    # `Found left-over process … Ignoring.` and both instances shared one world
    # and one pair of ports. KillMode=mixed must take the whole cgroup down.
    machine.succeed("pgrep -f 'pz-stub-jvm$'")
    machine.execute(
        "systemctl stop project-zomboid-demo.service",
        timeout=datetime.timedelta(seconds=120),
    )
    # A stop that had to SIGKILL the JVM is a failure the operator must see,
    # not a quiet `Deactivated successfully`.
    expect("project-zomboid-demo.service", "Result", "timeout")
    machine.wait_until_fails(
        "pgrep -f 'pz-stub-jvm$'", timeout=datetime.timedelta(seconds=30)
    )

    machine.succeed("systemctl start project-zomboid-demo.service")
    machine.wait_for_unit("project-zomboid-demo.service")
    logs = machine.succeed("journalctl -b -u project-zomboid-demo.service")
    assert "Found left-over process" not in logs, logs
  '';
}
