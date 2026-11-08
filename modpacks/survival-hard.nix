# modpacks/survival-hard.nix
#
# A high-difficulty, low-QoL pack: no workshop mods at all, so the whole point
# is that sandbox tuning does the work rather than mods.
#
# Included as the minimal example of a pack that touches only `defaultSandbox` —
# useful as a base to copy, and as the "nothing but sandbox vars" control case
# when testing whether a problem comes from a mod or from the settings.
{
  description = "No mods, hard sandbox. Everything tuned through SandboxVars.";

  workshopMods = [ ];
  mods = [ ];

  defaultSettings = {
    PVP = true;
    PauseEmpty = false;
    SaveWorldEveryMinutes = 15;
    DoLuaChecksum = false;
    # NOTE: there is deliberately no `SpawnPoint` here. PZ's `SpawnPoint=` is a
    # world coordinate triple — `SpawnPoint=0,0,0` is the origin — not a preset or
    # an index, so a small integer like `2` does not mean "no safehouse spawn", it
    # means two metres from the origin. An earlier draft of this pack asserted the
    # opposite and was wrong. Suppress safehouse spawns through the sandbox
    # settings below, not through this key.
  };

  defaultSandbox = {
    Zombies = 5; # Low (6 = None)
    DayLength = 8; # 5 hours (6 = 3 hours)
    Helicopter = 2; # Once (1 = Never)
    ZombieRespawn = 4; # None (the enum is 1..4, not 0..4)
    # There is no `ZombieDamage` key in Build 42. The nearest equivalents are
    # `ZombieLore.Strength` / `ZombieLore.Toughness`, which this module does not
    # expose yet; leaving the invented key here was a silent no-op.
    FoodLootNew = 0.4;
    RangedWeaponLootNew = 0.6;
    WeaponLootNew = 0.6; # melee and other non-tool weapons
    ClothingLootNew = 0.5;
    ContainerLootNew = 0.5;
    # Build 42 moved these into the `ZombieConfig` table; a flat key is an
    # unknown option and is ignored. The dotted form renders the table.
    "ZombieConfig.RedistributeHours" = 0;
    "ZombieConfig.PopulationStartMultiplier" = 1.5;
    "ZombieConfig.PopulationPeakMultiplier" = 2.0;
    MaximumLooted = 40; # Cap total looted items per container
  };
}
