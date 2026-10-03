# modpacks/vanilla-plus.nix
#
# A curated Vanilla+ bundle: well-known QoL, worldbuilding and map mods, at close
# to vanilla difficulty.
#
# Workshop item IDs come from the individual Workshop page URLs
# (https://steamcommunity.com/sharedfiles/filedetails/?id=<id>). The server
# downloads each into steamapps/workshop/content/108600/<id> and clients fetch
# them automatically on join.
#
# IMPORTANT — `workshopMods` are Workshop ids; `mods` are NOT. The `Mods=` key in
# a PZ server config takes each mod's `id=` from its own mod.info, whereas
# `WorkshopItems=` takes the Workshop item id. Mixing them up is the single most
# common reason a PZ server boots with no mods.
#
# modworkshop.net mods are not Workshop items at all: add them to `mods` and drop
# their folders into the install's Zomboid/mods.
{
  description = "Curated Vanilla+: QoL, worldbuilding and map mods at near-vanilla difficulty.";

  workshopMods = [
    {
      id = "2625441155";
      title = "Brita's Armor Pack";
    }
    {
      id = "2625840413";
      title = "Brita's Weapon Pack";
    }
    {
      id = "2679583791";
      title = "Project Zomboid eXpanded Helicopter Events";
    }
    {
      id = "2634209060";
      title = "Filibuster Rhymes' Used Cars!";
    }
    {
      id = "2705410157";
      title = "iTrackify";
    }
    {
      id = "2705410286";
      title = "Ched605's Fully Upgradable Tooltips";
    }
  ];

  # No non-Workshop mods in this pack.
  mods = [ ];

  # .ini keys any server on this pack inherits; a server's own `settings` win.
  defaultSettings = {
    PVP = true;
    PauseEmpty = true;
    SaveWorldEveryMinutes = 10;
    # Build 42 ships a Lua-checksum check that false-positives on Linux and
    # blocks clients from joining. See README 'Build 42'.
    DoLuaChecksum = false;
  };

  # SandboxVars any server on this pack inherits; a server's own `sandbox` wins.
  # Values are PZ's own numeric levels unless noted.
  defaultSandbox = {
    Zombies = 3; # High
    DayLength = 4; # 1 hour 30 minutes
    Helicopter = 3; # Sometimes
    ZombieRespawn = 3; # Low
    FoodLootNew = 0.8;
    RangedWeaponLootNew = 1.2;
    # Multipliers added in Build 42; older builds ignore unknown keys, so these
    # are safe to leave set.
    PopulationStartMultiplier = 1.0;
    PopulationPeakMultiplier = 1.0;
    RedistributeHours = 0;
    MaximumLooted = -1; # -1 = unlimited
  };
}
