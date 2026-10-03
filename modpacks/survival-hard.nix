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
    # No safehouse spawn for new characters.
    SpawnPoint = 2;
  };

  defaultSandbox = {
    Zombies = 5; # Extreme
    DayLength = 8; # 3 hours
    Helicopter = 2; # Never
    ZombieRespawn = 0; # Never
    ZombieDamage = 2;
    FoodLootNew = 0.4;
    RangedWeaponLootNew = 0.6;
    MeleeWeaponLootNew = 0.6;
    ClothingLootNew = 0.5;
    ContainerLootNew = 0.5;
    RedistributeHours = 0;
    MaximumLooted = 40; # Cap total looted items per container
    PopulationStartMultiplier = 1.5;
    PopulationPeakMultiplier = 2.0;
  };
}
