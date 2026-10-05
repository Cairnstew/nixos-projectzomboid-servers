# Host recipes

Task-oriented configurations. Each one is a complete, copy-pasteable fragment.

- [One server](#one-server)
- [Several servers on one host](#several-servers-on-one-host)
- [A fleet across hosts](#a-fleet-across-hosts)
- [Web consoles behind a proxy](#web-consoles-behind-a-proxy)
- [The tmux console](#the-tmux-console)
- [Writing your own modpack](#writing-your-own-modpack)
- [Local, non-Workshop mods](#local-non-workshop-mods)
- [Spawn points and regions](#spawn-points-and-regions)
- [Secrets](#secrets)
- [Hardening](#hardening)
- [Updating on a schedule](#updating-on-a-schedule)

---

## One server

[`examples/single-server`](../examples/single-server) is a complete, working
`nixosSystem` that its own `nix flake check` verifies. The short version:

```nix
{ inputs, ... }:
{
  imports = [ inputs.project-zomboid-servers.nixosModules.default ];
  nixpkgs.config.allowUnfree = true;

  services.project-zomboid-servers = {
    enable = true;
    dataDir = "/mnt/data/project-zomboid";   # saves grow without bound
    modpacks = inputs.project-zomboid-servers.modpacks;

    servers.main = {
      modpack = "vanilla-plus";
      defaultPort = 16261;
      udpPort = 16262;
      openFirewall = true;

      settings = { PVP = false; PauseEmpty = true; };
      sandbox = { Zombies = 2; DayLength = 6; };

      jvmOpts = "-Xmx6G -Xms3G";
      hardware = { memoryMax = "8G"; memoryHigh = "7G"; nice = 5; };
    };
  };
}
```

Two resources, not one: `jvmOpts` bounds the JVM heap, `hardware.memoryMax`
bounds the whole cgroup. Set both — a JVM that decides to grow past `-Xmx` should
not be able to take the host with it.

---

## Several servers on one host

Each entry becomes its own service, console socket and `Zomboid` home. They
share one Steam install, because PZ's binaries are identical — only the
configuration differs.

```nix
services.project-zomboid-servers = {
  enable = true;
  dataDir = "/mnt/data/project-zomboid";
  modpacks = inputs.project-zomboid-servers.modpacks;

  servers = {
    casual = {
      modpack = "vanilla-plus";
      defaultPort = 16261;
      udpPort = 16262;
      openFirewall = true;
      maxPlayers = 8;
      jvmOpts = "-Xmx4G -Xms2G";
      hardware.memoryMax = "6G";
    };

    survival = {
      modpack = "survival-hard";
      defaultPort = 16271;      # a unique pair per server
      udpPort = 16272;
      openFirewall = true;
      maxPlayers = 16;
      jvmOpts = "-Xmx8G -Xms4G";
      hardware.memoryMax = "10G";
    };
  };
};
```

Points that bite:

- **Both UDP ports must be unique per server.** A clash fails *evaluation* with
  an assertion naming both servers, rather than letting two servers each bind
  half a socket.
- `autoStart = false` on one server leaves it defined but stopped. Data is
  untouched, so it is safe to toggle.
- `softReset = true` is destructive and applies **on every start while true**.
  The NixOS module clears it once `systemd.nixos.reboot` takes effect, so it
  behaves as a declarative "reset my world" switch. Leave it on and every restart
  starts a new world. `Saves/` is left alone, so the old world is recoverable.

---

## A fleet across hosts

The module manages a *set* of servers, so the useful shape is one shared module
parameterised by role, imported by several hosts. Keep ports and `dataDir`
consistent; let each host own its own.

```nix
# flake.nix
{
  inputs.pz.url = "github:you/nixos-projectzomboid-servers";
  outputs = { self, nixpkgs, pz }:
    let
      forEachHost = f: nixpkgs.lib.genAttrs
        [ "pz-eu" "pz-us" ]   # systems; see "x86_64-linux only" in installing.md
        (system: f (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }) system);
    in {
      nixosConfigurations = forEachHost (pkgs: system: {
        "pz-${system}" = pkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./hosts/pz-common.nix
            {
              # Per-host identity. Everything else is shared.
              networking.hostName = "pz-${system}";
              services.project-zomboid-servers = {
                enable = true;
                dataDir = "/mnt/data/project-zomboid";
                modpacks = pz.modpacks;   # the SAME catalogue everywhere
                servers.eu = {
                  modpack = "vanilla-plus";
                  defaultPort = 16261;
                  udpPort = 16262;
                  openFirewall = true;
                  # This is what makes it a fleet: modworkshop.net mods often
                  # serve regional clients better than any single CDN route.
                  mods = [ "Moodle" "NoFuel" ];
                };
              };
            }
          ];
        };
      });
    };
}
```

Sharing one catalogue across hosts means every host resolves the same pack to
the same `Mods=` and `WorkshopItems=`, so a bug reproduced on one is reproducible
on all. Pin the input, or the fleet drifts with `nix flake update`.

---

## Web consoles behind a proxy

Consoles are ttyd instances on loopback. The module publishes them as **plain
data** rather than wiring in a proxy module it cannot depend on:

```nix
services.project-zomboid-servers = {
  enable = true;
  web = {
    enable = true;
    username = "pz";
    passwordFile = config.age.secrets.pz-console.path;
    # openFirewall stays false: expose through the proxy, not the raw port.
  };
};

# Map into whatever proxy you use. The dynamic key matters: see the
# `webConsoleUpstreams` section of docs/options.md for what a list-shaped
# proxy option wants instead.
proxy.upstreams = lib.mkMerge (map (u: {
  ${u.name} = {
    inherit (u) port path stripPrefix displayName;
  };
}) config.services.project-zomboid-servers.webConsoleUpstreams);
```

- `web.bind` defaults to `127.0.0.1`. Keep it that way, or bind a tailnet IP.
- `path` defaults to `/pz/<name>/` and `stripPrefix` to `true`, which ttyd needs.
- Ports are assigned from `web.portBase` (7682) in sorted server order, so they
  stay stable as long as you do not rename servers. Pin one with
  `servers.<name>.port` if you must.
- `web.user` gets scoped, password-less sudo for `systemctl {start,stop,restart,
  status}` **on the PZ units only**.

---

## The tmux console

For when you want `attach`, rather than a web console:

```nix
services.project-zomboid-servers = {
  enable = true;
  managementSystem = {
    systemd-socket.enable = false;
    tmux.enable = true;
  };
};
```

```bash
tmux -S /run/project-zomboid-servers/main.sock attach
```

Exactly one backend may be enabled, per server and globally — the module asserts
it. Two claims on the same stdin is exactly what that assertion prevents. Per
server, `managementSystem` inherits the global setting, so you can mix: socket
for most, tmux for the one you attach to by hand.

---

## Writing your own modpack

A pack is **plain data** — no module, no `pkgs`. That is what lets you keep it in
your own repo, or anywhere else, and share it independently of the module.

```nix
# my-packs.nix
{
  my-hardcore = {
    description = "No stamina loss, faster hunger, no safehouses";

    # Steam Workshop items. Order is preserved and becomes WorkshopItems=.
    # The id is a STRING, not a number.
    workshopMods = [
      { id = "2625441155"; title = "Chat"; }
      { id = "2705410157"; title = "Some Map Pack"; }
    ];

    # Local mod folder names — the id= values from each mod's mod.info.
    # These are NOT Workshop ids, and Mods= is COMMA separated where
    # WorkshopItems= is semicolon separated.
    mods = [
      "Moodle"
      "NoFuel"
    ];

    # .ini keys any server using this pack inherits. A server's own
    # `settings` wins over these.
    defaultSettings = {
      PVP = false;
      PauseEmpty = true;
      DoLuaChecksum = false;   # see "Hardening" — Linux false positive
    };

    # SandboxVars, same inheritance rule.
    defaultSandbox = {
      Zombies = 6;
      DayLength = 4;
    };
  };
}
```

Use it:

```nix
services.project-zomboid-servers = {
  enable = true;
  modpacks = inputs.pz.modpacks // import ./my-packs.nix;   # extend the catalogue
  servers.main.modpack = "my-hardcore";
};
```

Or extend a catalogue pack without copying it:

```nix
modpacks = inputs.pz.modpacks // {
  my-hardcore = inputs.pz.modpacks.vanilla-plus // {
    description = "vanilla-plus, but hostile";
    workshopMods = inputs.pz.modpacks.vanilla-plus.workshopMods ++ [
      { id = "2169438993"; }
    ];
  };
};
```

Inline `workshopMods`/`mods` on a *server* are **appended** to its pack's, which
is usually what you want for a one-off addition:

```nix
servers.main = {
  modpack = "vanilla-plus";
  mods = [ "NoFuel" ];        # in addition to the pack's own mods
};
```

> Never put a secret in `defaultSettings` or `defaultSandbox`. A pack is data
> that is easy to share, and evaluation **fails** if a known-secret key appears
> in either — the `secret-guard` check exists to prove that guard fires.

---

## Local, non-Workshop mods

Anything on modworkshop.net is distributed outside Steam, so it is not a Workshop
item. Drop the folder in the server's own mods directory and name it in `mods`:

```
<dataDir>/<servername>/Zomboid/mods/<ModFolder>/
```

```nix
servers.main.mods = [ "Moodle" ];   # the FOLDER name, or its mod.info id=
```

Note the path: `<dataDir>/<servername>/Zomboid/mods` — the server's own home,
**not** `serverDir`. `serverDir` is the shared Steam install.

PZ decides which files are mods, so a folder without a `mod.info` is ignored.
Because `mod.info` ships with CRLF line endings, validating a downloaded mod with
a shell `grep` needs `grep -llx -E "id=$mod[[:cntrl:]]?"`.

---

## Spawn points and regions

```nix
servers.main.spawn = {
  points = [
    { pos = [ 12067 6801 0 ]; }                        # profession defaults to unemployed
    { pos = [ 12068 6801 0 ]; }
    { pos = [ 5000 5000 0 ]; profession = "engineer"; }
  ];
  regions = [
    { name = "Mod Spawn"; file = "media/maps/ModName/spawnpoints.lua"; }
  ];
};
```

- `pos` is a world coordinate triple. So is PZ's own `SpawnPoint=` ini key:
  `SpawnPoint=0,0,0` is the origin, not a preset or an index.
- Points are grouped by `profession`, which is emitted as a bare Lua identifier
  when it is a valid one — matching PZ's own generated file — and
  bracket-quoted otherwise.
- Both files are written only when non-empty, and **removed** when you empty the
  option. Otherwise dropping it would silently do nothing to a running server,
  because PZ regenerates these files when they are absent.

---

## Secrets

The rendered base `.ini` is a store path: mode `444`, world-readable. So
anything in `settings` is plaintext that any local user can grep out of
`/nix/store`.

With agenix:

```nix
{
  age.secrets.pz-join = {
    file = ./secrets/pz-join.age;
    # owner/group must match what the server runs as, or it cannot read them
  };
  age.secrets.pz-rcon.file = ./secrets/pz-rcon.age;
  age.secrets.pz-admin.file = ./secrets/pz-admin.age;

  services.project-zomboid-servers.servers.main = {
    passwordFile = config.age.secrets.pz-join.path;              # → Password=
    secretFiles.RCONPassword = config.age.secrets.pz-rcon.path;
    adminAccount = {
      username = "seanc";
      passwordFile = config.age.secrets.pz-admin.path;
    };
  };
}
```

Or without agenix, anywhere on the host:

```nix
services.project-zomboid-servers.servers.main = {
  secretFiles = {
    RCONPassword = "/run/secrets/pz-rcon";
    DiscordToken = "/run/secrets/pz-discord";
  };
};
```

`secretFiles` accepts any `.ini` key, not just the four the module checks for
`Password` / `RCONPassword` / `DiscordToken` / `WebhookAddress`. Values are read
at start and written straight into the key; the value never enters a unit file,
the store, or `ps`.

`extraArgs` is the same trap in a different place — it is baked into a
world-readable unit. Use `adminAccount` for the admin password.

For the admin account, note the unavoidable caveat: PZ has no `.ini` key for it,
only `-adminusername` / `-adminpassword`, so the password is visible in `ps` for
the lifetime of the server. Reading it from a file at least keeps it out of
`systemctl cat` and out of the store.

---

## Hardening

**`DoLuaChecksum = false` is not optional in practice.** Build 42 has a Linux
false-positive bug in Lua checksum validation that blocks clients from joining.
Both bundled packs set it. Keep it off:

```nix
servers.main.settings.DoLuaChecksum = false;
```

**Firewall and ports.** `openFirewall` opens exactly this server's two UDP ports
and nothing else. Leave `upnp` at its default `false` — automatic port
forwarding punches holes in a firewall you deliberately kept closed, and cannot
work behind a container at all.

**Resource caps**, so one server cannot starve the host or its siblings:

```nix
servers.main.hardware = {
  memoryMax = "10G";      # hard cap; the unit is OOM-killed above it
  memoryHigh = "8G";       # soft throttle target
  cpuQuota = "200%";      # percentage of one core
  ioWeight = 500;
  nice = 5;
};
services.project-zomboid-servers.startLimitIntervalSec = 300;
services.project-zomboid-servers.startLimitBurst = 3;
```

A tighter `startLimitBurst` means a server that cannot start — bad port, missing
install, OOM — fails fast instead of restart-storming the host.

**Consoles.** `web.bind` defaults to loopback and `web.openFirewall` to false.
Expose through a proxy or a tailnet IP, not a raw port.

**Steam account.** Run under a dedicated Steam account if you use
`steam-run`; the install unit needs no credentials of its own for public
Workshop items.

---

## Updating on a schedule

```nix
services.project-zomboid-servers = {
  enable = true;
  updateSchedule = "daily";
  restartAfterUpdate = true;   # try-restart running servers
};
```

A timer validates the install and downloads new Workshop mods. `try-restart` is
used deliberately, so a server you had stopped stays stopped — only running ones
pick up the new binaries.

The update runs as its own timer-triggered unit rather than the boot-time one,
because the boot install is `RemainAfterExit` and a second `ExecStart` against it
would be a no-op.