# modpacks/viewpoint.nix
#
# "Project Viewpoint Vanilla+" — the Steam Workshop collection by OwenOasis
# (collection id 3812346398), reproduced here as a pack.
#
# 122 of the collection's 123 items. The one omission is deliberate and
# explained under the NOTE below.
#
# Order is the COLLECTION's own order, and it is load-bearing: ZombieBuddy
# (first) is the JVM agent every Java mod here requires via
# `require=\ZombieBuddy`, and ZombieBuddy additionally pins itself to the
# front of the resolved list. The launcher writes this order to
# WorkshopItems=, so reordering this list reorders mod loading.
#
# Project Viewpoint declares `javaJarFile=media/java/client/Viewpoint.jar`.
# ZombieBuddy skips any jar under `media/java/client/` on a dedicated
# server, so Viewpoint is safe to list: clients get the first-person
# renderer, the server ignores it. Its two add-ons (6244 3D models, 3D Blood
# VFX) are client-side assets for the same reason.
#
# NOTE [B42] ZombieBuddy Extensions (3807686870) is deliberately absent.
#   * it declares `versionMax=42.0`, so Project Zomboid treats it as
#     unavailable on the 42.21 the rest of this pack requires; and
#   * it ships no `javaJarFile` — its own description says "enabling this
#     entry does not install the replacement JAR".
#   It is therefore inert server-side, and listing an item PZ has hidden is
#   a needless way to provoke a missing-mod warning on join. The JVM agent
#   is supplied through the consumer's `javaAgent` option instead, which is
#   the supported hook (see modules/options.nix).
{
  description = "Project Viewpoint Vanilla+ (122 of the collection's 123 Workshop items).";

  workshopMods = [
    { id = "3619862853"; title = "ZombieBuddy"; }
    { id = "3809306528"; title = "Project Viewpoint"; }
    { id = "3810302175"; title = "6244 3D models for Viewpoint [sour_kisel]"; }
    { id = "3811472160"; title = "3d Blood VFX for Viewpoint (experimental)"; }
    { id = "3803984183"; title = "Project A-Life [ALIFE NPCS]"; }
    { id = "3661336777"; title = "Horse Mod [B42.20+/MP]"; }
    { id = "3461415167"; title = "[B42.20+/MP] Bicycle!"; }
    { id = "3404737883"; title = "Autotsar Motor Club B42"; }
    { id = "3761077099"; title = "[B42] Vanilla Firearms Expansion [CLASSIC]"; }
    { id = "3783094058"; title = "Vanilla Outfits Expanded"; }
    { id = "3401134276"; title = "Vanilla Gear Expanded"; }
    { id = "3270190005"; title = "Detailed Footwear"; }
    { id = "3171167894"; title = "that DAMN Library"; }
    { id = "3531611692"; title = "Lethal Stealth"; }
    { id = "3457132019"; title = "Specific Loot (KI5)"; }
    { id = "3663625294"; title = "Reorder The Hotbar (B42+ Fixed)"; }
    { id = "2699828474"; title = "Rebalanced Prop Moving"; }
    { id = "2956146279"; title = "Rain Cleans Blood [B42.20 + MP]"; }
    { id = "3783989538"; title = "Project Parkour"; }
    { id = "3413150945"; title = "More Damaged Objects [42MP]"; }
    { id = "3520758551"; title = "More Car Features + Spawn Zones Expansion"; }
    { id = "3777587577"; title = "LG Tape XP Indicator"; }
    { id = "3779164273"; title = "Improvised Silencers - Build 42.20 Compatibility"; }
    { id = "3426448380"; title = "Immersive Suicide [B42/B41]"; }
    { id = "3607686447"; title = "Immersive Blackouts [B42MP]"; }
    { id = "2447729538"; title = "Fluffy Hair [B41/B42]"; }
    { id = "3682936016"; title = "Equipment UI – STABLE +"; }
    { id = "3671176591"; title = "dustinguished bolt cutters"; }
    { id = "3461263912"; title = "Clean HotBar [B42]"; }
    { id = "2313387159"; title = "Better Sorting"; }
    { id = "3387539308"; title = "Auto Mechanics"; }
    { id = "3775549570"; title = "Alice's Weapon Sling"; }
    { id = "3624971238"; title = "Yet Another PZ LIbrary"; }
    { id = "3642084851"; title = "[B41/42] Minimal Sidebar (Auto Hide)"; }
    { id = "3402491515"; title = "Tsar's Common Library B42"; }
    { id = "3387957272"; title = "[B42.20] Detailed Descriptions for Occupations and Traits"; }
    { id = "3749026793"; title = "[B42.20] Carry Visible Items In Hands [WIP]"; }
    { id = "3806955469"; title = "True Cargo - Project Full HD"; }
    { id = "3740300378"; title = "KI5 Mini-fixes"; }
    { id = "3501302358"; title = "Vehicle Seat UI (KI5)"; }
    { id = "3436499337"; title = "Vehicle Military Zones"; }
    { id = "2625625421"; title = "Containers!"; }
    { id = "3330403100"; title = "Trailers!"; }
    { id = "3670064951"; title = "Campers!"; }
    { id = "2932547723"; title = "'93 Lincoln Town Car + Limo"; }
    { id = "3088951320"; title = "'93 Ford Taurus"; }
    { id = "3001592312"; title = "'93 Ford Mustang"; }
    { id = "3073430075"; title = "'93 Ford F-Series"; }
    { id = "2969343830"; title = "'93 Ford CF8000 Elgin Street Sweeper"; }
    { id = "3152529790"; title = "'93 Chevrolet Suburban / Silverado"; }
    { id = "2846036306"; title = "'92 NISSAN Skyline GT-R (R32)"; }
    { id = "3287727378"; title = "'92 Jeep YJ Wrangler"; }
    { id = "2962175696"; title = "'92 Ford Crown Victoria"; }
    { id = "2642541073"; title = "'92 AM General M998 + M101A3 Cargo trailer"; }
    { id = "2409333430"; title = "'91 RANGE ROVER Classic"; }
    { id = "3504401781"; title = "'91 Nissan 240SX"; }
    { id = "3770890864"; title = "'91 Lexus LS400"; }
    { id = "3008795514"; title = "'91 Geo Metro"; }
    { id = "3539691958"; title = "'91 Ford Ranger"; }
    { id = "3366300557"; title = "'91 Ford LTD Crown Victoria / Country Squire"; }
    { id = "2942793445"; title = "'90 Pierce Arrow Pumper and Ladder Trucks"; }
    { id = "2952802178"; title = "'90 Ford F350 Ambulance"; }
    { id = "3110913021"; title = "'90 BMW 3 Series (E30)"; }
    { id = "3292659291"; title = "'89 Volvo 200 Series"; }
    { id = "3570973322"; title = "'89 LAND ROVER Defender"; }
    { id = "2932549988"; title = "'89 Isuzu Trooper"; }
    { id = "2886833398"; title = "'89 Ford Bronco"; }
    { id = "3034636011"; title = "'89 Dodge Caravan"; }
    { id = "3435796523"; title = "'88 Toyota Hilux"; }
    { id = "2886832936"; title = "'88 Chevrolet S10"; }
    { id = "3052360250"; title = "'87 Toyota MR2"; }
    { id = "3779315249"; title = "'87 Toyota Corolla AE92"; }
    { id = "3110911330"; title = "'87 Ford B700/F700 Trucks"; }
    { id = "3196180339"; title = "'87 Chevrolet Suburban"; }
    { id = "3226885926"; title = "'87 Buick Regal"; }
    { id = "2566953935"; title = "'86 Oshkosh P19A + Military Trailers"; }
    { id = "2870394916"; title = "'86 Ford Econoline E-150 + Pop Culture vans"; }
    { id = "3428008364"; title = "'86 Chevrolet CUCVs + M101A2 Trailer"; }
    { id = "3413706334"; title = "'85 Pontiac Parisienne"; }
    { id = "3418253716"; title = "'85 Oldsmobile Delta 88"; }
    { id = "3614034284"; title = "'85 Chevrolet Step-Van"; }
    { id = "3413704851"; title = "'85 Chevrolet Caprice / Impala"; }
    { id = "3418252689"; title = "'85 Buick LeSabre"; }
    { id = "3601417745"; title = "'84 Oldsmobile 98 Regency"; }
    { id = "2805630347"; title = "'84 Mercedes Benz W460"; }
    { id = "3409287192"; title = "'84 Jeep XJ Cherokee"; }
    { id = "3684254299"; title = "'84 Chevrolet Corvette"; }
    { id = "3592777775"; title = "'84 Cadillac DeVille"; }
    { id = "3596903773"; title = "'84 Buick Electra"; }
    { id = "3379334330"; title = "'82 Porsche 911"; }
    { id = "3320947974"; title = "'82 Pontiac Firebird"; }
    { id = "2618213077"; title = "'82 Oshkosh M911 + Military Semi-Trailers"; }
    { id = "2886832257"; title = "'82 Jeep J10"; }
    { id = "3253385114"; title = "'81 DeLorean DMC-12"; }
    { id = "3703948448"; title = "'79 Chevrolet Camaro"; }
    { id = "3726526329"; title = "'78 Lamborghini Countach"; }
    { id = "2799152995"; title = "'78 AM General M35 Series Trucks"; }
    { id = "3346905070"; title = "'77 Pontiac Firebird"; }
    { id = "3730833846"; title = "'76 Chrysler New Yorker"; }
    { id = "3161951724"; title = "'76 Chevrolet K Series"; }
    { id = "3213391371"; title = "'75 Pontiac Grand Prix"; }
    { id = "3743371090"; title = "'73 NISSAN Skyline GT-R"; }
    { id = "3490370700"; title = "'73 Ford Falcon"; }
    { id = "3642935062"; title = "'70 Plymouth Road Runner"; }
    { id = "2913633066"; title = "'70 Plymouth Barracuda"; }
    { id = "3670063857"; title = "'70 Ford Escort"; }
    { id = "2873290424"; title = "'70 Dodge Challenger"; }
    { id = "3766571591"; title = "'70 Chevrolet Chevelle / El Camino"; }
    { id = "2937786633"; title = "'69 Mini Mk2"; }
    { id = "3756938756"; title = "'69 Ford Mustang"; }
    { id = "3631989559"; title = "'69 Dodge Charger"; }
    { id = "2991201484"; title = "'69 Chevrolet Camaro"; }
    { id = "3258343790"; title = "'68 Pontiac Firebird"; }
    { id = "3026723485"; title = "'67 Shelby GT500 + Eleanor"; }
    { id = "2478247379"; title = "'67 Cadillac Gage Commando"; }
    { id = "3447272250"; title = "'66 Pontiac LeMans / GTO"; }
    { id = "3566868353"; title = "'65 Pontiac Banshee"; }
    { id = "3041122351"; title = "'63 Volkswagen Type 2 Van"; }
    { id = "3005903549"; title = "'63 Volkswagen 1300 Beetle"; }
    { id = "3787530735"; title = "'62 Daimler Ferret"; }
    { id = "2772575623"; title = "'59 Cadillac Miller-Meteor + ECTO-1"; }
    { id = "2900580391"; title = "'49 Dodge Power Wagon Crew Cab"; }
  ];

  # `Mods=` — the list PZ actually LOADS. `WorkshopItems=` only says what to
  # download and require; with `SelfManagedMods=true` the game will not derive
  # `Mods=` from it, so a workshop-only pack that omits this loads NOTHING (the
  # server still boots and listens, which is what makes it easy to miss).
  #
  # These are each mod's mod.info `id=`, not the Workshop id, comma-separated.
  # 147 ids from the pack's 122 Workshop items — several KI5 items ship
  # more than one mod (variants), which is why the counts differ.
  mods = [
    "49powerWagon"
    "59meteor"
    "62daimlerFerret"
    "63Type2Van"
    "63beetle"
    "65banshee"
    "66pontiacLeMans"
    "67commando"
    "67gt500"
    "68firebird"
    "69camaro"
    "69charger"
    "69fordMustang"
    "69fordMustangExtra"
    "69mini"
    "69mini_ItalianJob"
    "69mini_MrBean"
    "69mini_PitbullSpecial"
    "70barracuda"
    "70chevelle"
    "70dodge"
    "70fordEscort"
    "70roadRunner"
    "73fordFalcon"
    "73fordFalconPS"
    "73nissanGTR"
    "75grandPrix"
    "76chevyKseries"
    "76chevyKseriesExpanded"
    "76chryslerNewYorker"
    "77firebird"
    "78amgeneralM35A2"
    "78amgeneralM35A2extra"
    "78amgeneralM49A2C"
    "78amgeneralM50A3"
    "78amgeneralM62"
    "78lamboCountach"
    "79camaro"
    "81deloreanDMC12"
    "81deloreanDMC12BTTF"
    "82firebird"
    "82firebirdKITT"
    "82jeepJ10"
    "82jeepJ10t"
    "82oshkoshM911"
    "82porsche911"
    "84buickElectra"
    "84cadillacDeVille"
    "84corvette"
    "84jeepXJ"
    "84merc"
    "84oldsmobile98"
    "85buickLeSabre"
    "85chevyCaprice"
    "85chevyStepVan"
    "85chevyStepVanexpanded"
    "85oldsmobileDelta88"
    "85pontiacParisienne"
    "86chevyCUCV"
    "86fordE150"
    "86fordE150dnd"
    "86fordE150expanded"
    "86fordE150mm"
    "86fordE150pd"
    "86oshkoshP19A"
    "87buickRegal"
    "87chevySuburban"
    "87fordB700"
    "87toyotaCorolla"
    "87toyotaMR2"
    "88chevyS10"
    "88toyotaHilux"
    "89defender"
    "89dodgeCaravan"
    "89fordBronco"
    "89trooper"
    "89volvo200"
    "90bmwE30"
    "90fordF350ambulance"
    "90pierceArrow"
    "91fordLTD"
    "91fordRanger"
    "91geoMetro"
    "91lexusLS400"
    "91nissan240sx"
    "91range"
    "92amgeneralM998"
    "92amgeneralM998extra"
    "92fordCVPI"
    "92jeepYJ"
    "92jeepYJJP18"
    "92nissanGTR"
    "93chevySuburban"
    "93chevySuburbanExpanded"
    "93fordElgin"
    "93fordF350"
    "93fordTaurus"
    "93mustangSSP"
    "93townCar"
    "AutoMechanics"
    "BetterSortCC"
    "BicycleMod"
    "CVI"
    "CleanHotBar"
    "DetailedDescriptionsForOccupationsAndTraits"
    "DetailedFootwear"
    "ECTO1"
    "EQUIPMENT_UI"
    "EQUIPMENT_UI_B42"
    "FH"
    "Horse"
    "ImmersiveBlackouts"
    "ImprovisedSilencers"
    "KI5campers"
    "KI5minifixes"
    "KI5trailers"
    "LGTapeXP"
    "MinimalSidebar"
    "MoreDamagedObjects"
    "PFHDTrueCargo"
    "PZVoxelStudioViewpoint"
    "Parkour"
    "ProjectALifeNPCs"
    "REORDER_THE_HOTBAR"
    "RET_LethalStealth"
    "RainCleansBlood"
    "RebalancedPropMoving"
    "SpecLoot"
    "VFExpansion1"
    "VMZNEW"
    "VSUIKI5"
    "VanillaGearExpanded"
    "VanillaOutfitsExpanded"
    "Viewpoint"
    "ViewpointBloodFX"
    "WayMoreCars"
    "YAPZLib"
    "ZombieBuddy"
    "alicesWeaponSling"
    "alicesWeaponSlingRadialMenu"
    "amclub"
    "damnlib"
    "dustinguished_bolt_cutters"
    "equipmentuipatch"
    "isoContainers"
    "stanks_suicide"
    "tsarslib"
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

  # Deliberately no per-mod SandboxVars entries: a mod ships its own defaults in
  # media/sandbox-options.txt and the game applies them unaided. Only a server
  # that wants to OVERRIDE a mod's default needs an entry, and that belongs on
  # the server, not in the shared pack.
  defaultSandbox = { };
}
