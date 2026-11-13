# modpacks/vanilla-plus.nix
#
# A curated Vanilla+ bundle: a small, verified Build 42 QoL set at close to
# vanilla difficulty. Deliberately no maps, vehicles or content overhauls — it is
# the pack to reach for when the world should still feel vanilla.
#
# `workshopMods` are Workshop ids; `mods` are each mod's own `mod.info` `id=`,
# which is what `Mods=` takes. The two are different namespaces and mixing them
# up is the single most common reason a PZ server boots with no mods — which is
# exactly what this file used to do: it listed six Workshop items and no Mod IDs,
# so the install downloaded them and the server loaded nothing.
#
# Every pair below is copied from `viewpoint.nix`, where the same item and its
# Mod ID are already in use on Build 42. Keep `mods` in sync with
# `workshopMods`; `pz-pack-doctor` exists to catch drift after a download.
{
  description = "Curated Vanilla+: a small Build 42 QoL set at near-vanilla difficulty.";

  workshopMods = [
    { id = "2847184718"; title = "Proximity Inventory B42.20+"; } # ProximityInventory
    { id = "3789660055"; title = "Container Capacity Indicator [B42]"; } # ContainerCapacityIndicator
    { id = "3494474677"; title = "[B42] More Item Information"; } # MoreItemInformation
    { id = "3775659041"; title = "Minimal Display Bars - Build 42.21 (Standalone)"; } # MinimalDisplayBarsB4220
    { id = "3786647452"; title = "Read While Walking - Updated (B41 + B42)"; } # SimpleReadWhileWalkingUpdated
    { id = "3781533687"; title = "True Sleep - Better Multiplayer Sleep"; } # TrueSleep
  ];

  mods = [
    "ProximityInventory"
    "ContainerCapacityIndicator"
    "MoreItemInformation"
    "MinimalDisplayBarsB4220"
    "SimpleReadWhileWalkingUpdated"
    "TrueSleep"
  ];

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
    # Build 42 moved these into the `ZombieConfig` table; a flat key is an
    # unknown option and is ignored silently. Older builds ignore the dotted
    # keys instead, which is harmless.
    "ZombieConfig.PopulationStartMultiplier" = 1.0;
    "ZombieConfig.PopulationPeakMultiplier" = 1.0;
    "ZombieConfig.RedistributeHours" = 0;
    MaximumLooted = 0; # 0 = never pre-looted (the option is 0–200; -1 was out of range)
  };
}
