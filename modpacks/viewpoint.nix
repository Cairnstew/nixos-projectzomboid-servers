# modpacks/viewpoint.nix
#
# "Project Viewpoint Vanilla+" — updated from Steam Workshop collection by OwenOasis
# (collection id 3812346398)
#
{
  description = "Project Viewpoint Vanilla+ (updated from collection 3812346398 + progression/mechanics additions).";

  workshopMods = [
    { id = "3619862853"; title = "ZombieBuddy"; }
    { id = "3809306528"; title = "Project Viewpoint"; }
    { id = "3810302175"; title = "6282 3D models for Viewpoint [sour_kisel]"; }
    { id = "3811472160"; title = "3d Blood VFX for Viewpoint (experimental)"; }
    { id = "3813801053"; title = "Blood FX for Viewpoint - Fixes"; }
    { id = "3803984183"; title = "Project A-Life [ALIFE NPCS]"; }
    { id = "3661336777"; title = "Horse Mod [B42.20+/MP]"; }
    { id = "3461415167"; title = "[B42.20+/MP] Bicycle!"; }
    { id = "3456675747"; title = "[B42.20+ MP] Skateboard!"; }
    { id = "3404737883"; title = "Autotsar Motor Club B42"; }
    { id = "3783444342"; title = "[B42]Aviation Core (Beta)"; }
    { id = "3409723807"; title = "[B42] UH-1B Helicopter (Beta)"; }
    { id = "3812896812"; title = "Helicopter Fix - Project Viewpoint"; }
    { id = "3761077099"; title = "[B42] Vanilla Firearms Expansion [CLASSIC]"; }
    { id = "2799742455"; title = "Improvised Silencers by Maxwell218"; }
    { id = "3813760573"; title = "HorseMod + Viewpoint Controls Patch"; }
    { id = "3815999052"; title = "OldPoint - Rotating Overhead Camera [B42 / Viewpoint]"; }
    { id = "3812612054"; title = "Project Viewpoint: Recoil & ADS"; }
    { id = "3812864848"; title = "Viewpoint True Ballistics"; }
    { id = "3813194971"; title = "Viewpoint - Advanced Throwables"; }
    { id = "3813908957"; title = "Project Viewpoint: True Weathers & Lighting"; }
    { id = "3813489363"; title = "SMB steps"; }
    { id = "3824459820"; title = "Build Your Own Kayak [B42]"; }
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
    { id = "3520758551"; title = "More Car Features + Spawn Zones Expansion"; }
    { id = "3777587577"; title = "LG Tape XP Indicator"; }
    { id = "3779164273"; title = "Improvised Silencers - Build 42.20 Compatibility"; }
    { id = "3426448380"; title = "Immersive Suicide [B42/B41]"; }
    { id = "3607686447"; title = "Immersive Blackouts [B42MP]"; }
    { id = "2447729538"; title = "Fluffy Hair [B41/B42]"; }
    { id = "3682936016"; title = "Equipment UI – STABLE +"; }
    { id = "3671176591"; title = "dustinguished bolt cutters"; }
    { id = "2313387159"; title = "Better Sorting"; }
    { id = "3775549570"; title = "Alice's Weapon Sling"; }
    { id = "3624971238"; title = "Yet Another PZ LIbrary"; }
    { id = "3642084851"; title = "[B41/42] Minimal Sidebar (Auto Hide)"; }
    { id = "3402491515"; title = "Tsar's Common Library B42"; }
    { id = "3387957272"; title = "[B42.20] Detailed Descriptions for Occupations and Traits"; }
    { id = "3749026793"; title = "[B42.20] Carry Visible Items In Hands [WIP]"; }
    { id = "3816442251"; title = "Viewpoint: Living Props"; }
    { id = "3815630947"; title = "Viewpoint Rolling Hills"; }
    { id = "3817555882"; title = "Rolling Hills Physics Addon (Project Viewpoint)"; }
    { id = "3814398576"; title = "Surface Fix - Project Viewpoint"; }
    { id = "3812151347"; title = "Door Fix - Project Viewpoint"; }
    { id = "3806955469"; title = "True Cargo - Project Full HD"; }
    { id = "3781616141"; title = "[B42.20+] Vehicle Aim Roof Fix"; }
    { id = "3785695033"; title = "[B42.20+] Vehicle Enter/Exit Fix"; }
    { id = "3783874874"; title = "[B42.20+] Vehicle Weapon Clipping Fix"; }
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
    { id = "3821300859"; title = "Knox Network Progression [B42]"; }
    { id = "3813972279"; title = "[B42] Vehicle Manager by Minidoracat"; }
    { id = "3820158257"; title = "[B41/B42] Minimal Car Dashboard (Auto-Hide)"; }
    { id = "3814684002"; title = "[B42] Knox Pass by Minidoracat"; }

    # ── Sewing / tailoring progression ──────────────────────────────────────
    # All Build 42 and multiplayer-safe (Workshop `Multiplayer` tag, or verified
    # from the download: items/recipes/shared Lua only). Dependencies first:
    #   TooltipLib                      -> My Tailor Is Rich
    #   ChuckleberryFinnAlertSystem     -> errorMagnifier -> Interactive Tailoring
    #   InteractiveTailoring            -> Interactive Tailoring MP Fix
    # Advanced Fabrics must load last among clothing mods.
    { id = "3694097672"; title = "Tooltiplib - Tooltip Framework for Modders"; }
    # STUB: Interactive Tailoring/errorMagnifier require a since-removed mod by
    # this ID; this blank item fills the dependency (450 subscribers, no content).
    { id = "3496670149"; title = "Mod Update and Alert System [STUB]"; }
    { id = "2896041179"; title = "errorMagnifier"; }
    { id = "3522680786"; title = "Interactive Tailoring"; }
    { id = "3816028300"; title = "Interactive Tailoring MP Fix"; }
    { id = "3803921146"; title = "Wildwrought: Tailoring Practice"; }
    { id = "3822541989"; title = "Practice - Tailoring - Gunny Sack"; }
    { id = "3684942821"; title = "[WYD] VHS Skill Tapes: Tailoring"; }
    { id = "3792833867"; title = "Tailoring XP for Salvaging"; }
    { id = "2879667197"; title = "PZ More Tailoring"; }
    { id = "3675200093"; title = "PZ More Tailoring 2"; }
    { id = "3794487959"; title = "StitchnSalvage"; }
    { id = "3786896656"; title = "Combine Leather / Sew Leather"; }
    { id = "3803789558"; title = "Knit Bandage"; }
    { id = "3789037653"; title = "Tailor's Cut - Cut Clothing Holes Anywhere"; }
    { id = "3416525606"; title = "Recut"; }
    { id = "2142622992"; title = "Repair Any Clothes"; }
    { id = "3667745474"; title = "Rip-A-Holic"; }
    { id = "3810122988"; title = "My Tailor Is Rich - Clothing & Shoe Sizes"; }
    { id = "3822249892"; title = "Master Sewing Kit"; }
    { id = "3696197915"; title = "Suture Needles are for Sewing"; }
    { id = "3794060081"; title = "Real Zomboid Batch Tailoring"; }
    { id = "3810346562"; title = "Clothing Damage Alerts (Torn Threads)"; }
    { id = "3787179508"; title = "Advanced Fabrics - Layered Protection"; } # load last

    # ── Mechanics / vehicle repair progression ──────────────────────────────
    # Better Auto Mechanics replaces the old Auto Mechanics (3387539308),
    # removed because it has no MP support. VRO must load after vehicle mods; its
    # whole-vehicle salvage lives in a second mod in the same Workshop item.
    # Vanilla Vehicle Parts ships one addon per vehicle pack: only the DAMN
    # Library and Autotsar Motorclub addons apply here (both packs are below).
    { id = "3635856965"; title = "Better Auto Mechanics [B42.20.4+ MP+SP]"; }
    { id = "2744114761"; title = "Craft Engine Parts"; }
    { id = "3795571681"; title = "Vanilla Vehicle Parts"; }
    { id = "2757712197"; title = "Vehicle Repair Overhaul"; }
    { id = "3744391882"; title = "Consistent Vehicle Repairs"; }
    { id = "3543612325"; title = "Restore Engine Quality [B42]"; }
    { id = "3464551542"; title = "Functional Car Lift"; }
    { id = "3793163745"; title = "Area Tasks - Select an area for vanilla tasks [B42]"; }
    { id = "3801094884"; title = "Area Tasks: Auto Mechanics"; }
    { id = "3677886085"; title = "Mechanics Eye"; }
    { id = "3827271522"; title = "GarageWorks [B42]"; }
    { id = "3800858172"; title = "Vehicle Armor Crafting [B42]"; }
    { id = "3729609290"; title = "Engine Upgrade Kit & Extra Fluid Tank[SP/MP][42.21+]"; }
    { id = "2945424264"; title = "Immersive Cars: Parts Picked"; }

    # ── Salvage / recycling ────────────────────────────────────────────────
    # Build 42 + multiplayer. Teardown and Recycling of Waste are a paired
    # loop: Teardown breaks junk down to scrap, Recycling of Waste smelts it
    # back up. Both are static recipes (no client-side item creation, no item
    # redefinitions). Improvised Glass recycles shards into panes/windows.
    { id = "3792605253"; title = "Teardown - Junk Into Materials"; }
    { id = "3470205514"; title = "[B42]Recycling of waste"; }
    { id = "3787169788"; title = "Improvised Glass & Windows (B42 Stable)"; }

    # Structural salvage / cleanup. Dismantle All Buildables is deliberately
    # omitted: it adds the same Dismantle option to workstations/structures
    # that Kentucky Workstation Salvage already covers.
    { id = "3783972702"; title = "Kentucky Workstation Salvage"; }
    { id = "3776658529"; title = "[42.20 SP/MP] Dismantle All Electronics"; }
    { id = "3793407081"; title = "Remove Debris (Tree Stumps & Boulders) / Delete Trash Tiles"; }
    { id = "3779330500"; title = "VRO Salvage Condition Lock"; }

    # ── Corpse handling / usage ────────────────────────────────────────────
    # Build 42 + multiplayer. Zombie Butchery is a server-authoritative
    # butchering path; Better Corpse Burning does its fire work server-side;
    # Corpse Dumper removes bodies via bins. The two fixes cover MP corpse
    # loot (requires ZombieBuddy) and the Viewpoint 3D corpse-menu NPE.
    { id = "3787607014"; title = "Zombie Butchery [B42]"; }
    { id = "3790089095"; title = "Better Corpse Burning"; }
    { id = "3684602722"; title = "Corpse Dumper"; }
    { id = "3812132807"; title = "[B42] MP Vanilla Zombie Corpse Fix"; }
    { id = "3818966539"; title = "Viewpoint 42.21 Corpse Menu Fix"; }

    # Additional, non-overlapping corpse mechanics: chipper/compost, vehicle
    # towing, medical autopsy, dragging XP, floor gather/delete hotkey,
    # door opening while dragging, player-corpse persistence, server-side
    # zombie-corpse cap, sickness recovery and indoor stink propagation.
    { id = "3795893288"; title = "Mulch - Corpse Disposal & Compost"; }
    { id = "3782664078"; title = "Corpse Towing"; }
    { id = "3791146188"; title = "Corpse Autopsy"; }
    { id = "3404074048"; title = "[B42] Exercise With Corpses"; }
    { id = "3414546041"; title = "[B42/41] Gather Floor Items & Corpse"; }
    { id = "3784955576"; title = "Open Doors While Dragging Corpses"; }
    { id = "3658915668"; title = "Persistent Player Corpses"; }
    { id = "3823949980"; title = "Zombie Corpse Limiter [B42 MP]"; }
    { id = "3687841589"; title = "Adjustable Corpse Sickness"; }
    { id = "3825280124"; title = "True Corpse Stink"; }
  ];

  mods = [
    "ZombieBuddy"
    "Viewpoint"
    "PZVoxelStudioViewpoint"
    "ViewpointBloodFX"
    "air"
    "ViewpointBloodFXAddon"
    "ProjectALifeNPCs"
    "Horse"
    "BicycleMod"
    "SkateboardMod"
    "amclub"
    "AviationCore"
    "UH"
    "ViewpointHeli"
    "VFExpansion1"
    "ImprovisedSilencers"
    "ImprovisedSilencersVFEPatch"
    "HorsePatch3d"
    "OldPoint"
    "ProjectViewpointADS"
    "ViewpointTrueBallistics"
    "ViewpointAdvancedThrowables"
    "ViewpointTrueWeathers"
    "ViewpointTrueWeathersGameplay"
    "SMB_steps"
    "BuildYourOwnKayak"
    "VanillaOutfitsExpanded"
    "VanillaGearExpanded"
    "DetailedFootwear"
    "damnlib"
    "damnlibGlass"
    "RET_LethalStealth"
    "SpecLoot"
    "REORDER_THE_HOTBAR"
    "RebalancedPropMoving"
    "RainCleansBlood"
    "Parkour"
    "save"
    "WayMoreCars"
    "LGTapeXP"
    "stanks_suicide"
    "ImmersiveBlackouts"
    "FH"
    "EQUIPMENT_UI_B42"
    "EQUIPMENT_UI"
    "dustinguished_bolt_cutters"
    "BetterSortCC"
    "game"
    "alicesWeaponSling"
    "alicesWeaponSlingRadialMenu"
    "YAPZLib"
    "MinimalSidebar"
    "tsarslib"
    "DetailedDescriptionsForOccupationsAndTraits"
    "CVI"
    "ViewpointLivingProps"
    "ViewpointRollingHills"
    "RollingHillsPhysics"
    "ViewpointSurface"
    "ViewpointDoor"
    "PFHDTrueCargo"
    "CarRoofFix"
    "CarEnterExitFix"
    "CarWeaponFix"
    "KI5minifixes"
    "VSUIKI5"
    "VMZNEW"
    "isoContainers"
    "KI5trailers"
    "KI5campers"
    "93townCar"
    "93fordTaurus"
    "93mustangSSP"
    "93fordF350"
    "93fordElgin"
    "93chevySuburban"
    "93chevySuburbanExpanded"
    "92nissanGTR"
    "92jeepYJ"
    "92jeepYJJP18"
    "92fordCVPI"
    "92amgeneralM998"
    "91range"
    "91nissan240sx"
    "91lexusLS400"
    "91geoMetro"
    "91fordRanger"
    "91fordLTD"
    "90pierceArrow"
    "90fordF350ambulance"
    "90bmwE30"
    "89volvo200"
    "89defender"
    "89trooper"
    "89fordBronco"
    "89dodgeCaravan"
    "88toyotaHilux"
    "88chevyS10"
    "87toyotaMR2"
    "87toyotaCorolla"
    "87fordB700"
    "87chevySuburban"
    "87buickRegal"
    "86oshkoshP19A"
    "86fordE150"
    "86fordE150dnd"
    "86fordE150mm"
    "86fordE150pd"
    "86fordE150expanded"
    "86chevyCUCV"
    "85pontiacParisienne"
    "85oldsmobileDelta88"
    "85chevyStepVan"
    "85chevyStepVanexpanded"
    "85chevyCaprice"
    "85buickLeSabre"
    "84oldsmobile98"
    "84merc"
    "84jeepXJ"
    "84corvette"
    "84cadillacDeVille"
    "84buickElectra"
    "82porsche911"
    "82firebird"
    "82firebirdKITT"
    "82oshkoshM911"
    "82jeepJ10"
    "82jeepJ10t"
    "81deloreanDMC12"
    "81deloreanDMC12BTTF"
    "79camaro"
    "78lamboCountach"
    "78amgeneralM35A2"
    "78amgeneralM35A2extra"
    "78amgeneralM49A2C"
    "78amgeneralM50A3"
    "78amgeneralM62"
    "77firebird"
    "76chryslerNewYorker"
    "76chevyKseries"
    "76chevyKseriesExpanded"
    "75grandPrix"
    "73nissanGTR"
    "73fordFalcon"
    "73fordFalconPS"
    "70roadRunner"
    "70barracuda"
    "70fordEscort"
    "70dodge"
    "70chevelle"
    "69mini"
    "69mini_ItalianJob"
    "69mini_MrBean"
    "69mini_PitbullSpecial"
    "69fordMustang"
    "69fordMustangExtra"
    "69charger"
    "69camaro"
    "68firebird"
    "67gt500"
    "67commando"
    "66pontiacLeMans"
    "65banshee"
    "63Type2Van"
    "63beetle"
    "62daimlerFerret"
    "59meteor"
    "ECTO1"
    "49powerWagon"
    "KnoxNetworkProgression"
    "MinidoracatVehicleManagerFor42"
    "AutoHideCarDash"
    "MinidoracatKnoxPassFor42"

    # ── Sewing / tailoring progression ──────────────────────────────────────
    # Load order: dependencies before dependents; AdvancedFabricsMP last.
    "TooltipLib"
    "ChuckleberryFinnAlertSystem" # STUB item; fills a removed dependency
    "errorMagnifier"
    "InteractiveTailoring"
    "InteractiveTailoringMPFix"
    "WWS_TailoringPractice"
    "PracticeTailoringGunny"
    "SkillTapesTailor42"
    "TailoringXP"
    "PZMoreTailoring"
    "PZMoreTailoring2"
    "StitchnSalvage"
    "TFC_CombineLeatherMod"
    "KnitBandage"
    "TailorsCut"
    "RecutB42"
    "RepairAnyClothes"
    "rip-a-holic"
    "batman_MyTailorIsRich"
    "MasterSewingKit"
    "SutureNeedles4Sewing"
    "RealZomboidBatchTailoring"
    "TornThreads"
    "AdvancedFabricsMP"

    # ── Mechanics / vehicle repair progression ──────────────────────────────
    # One Craft Engine Parts tier only; one VRO core + its salvage addon;
    # Vanilla Vehicle Parts core before its per-pack addons.
    "better-auto-mechanics"
    "CraftEnginePartsModerate"
    "VanillaVehicleParts"
    "VVPCarModels"
    "VVPMotoModels"
    "DamnlibVanillaPartsPatch"
    "VVPHideRecipes"
    "VehicleRepairOverhaul"
    "VehicleSalvageOverhaulB42"
    "ConsistentVehicleRepairs"
    "Ivmakk_RestoreEngineQuality"
    "FunctionalCarLift"
    "AreaTasks"
    "AreaTasksAutoMechanics"
    "MechanicsEye"
    "GarageWorks"
    "VehicleArmorCrafting"
    "vac_engine_upgrade_kit"
    "ImmersiveCarsPicking"

    # ── Salvage / recycling ────────────────────────────────────────────────
    # Teardown produces the scrap; WasteConversion smelts it upward.
    "Teardown"
    "WasteConversion"
    "ImprovisedGlassB42"
    "KentuckyWorkstationSalvage"
    "DismantleAllElectronics"
    "TFC_RemoveDebrisMod"
    "VROSalvageConditionLock" # requires VehicleSalvageOverhaulB42 (loaded above)

    # ── Corpse handling / usage ────────────────────────────────────────────
    # B42MPZombieCorpseFix requires ZombieBuddy (already first);
    # the Viewpoint corpse-menu fix requires Viewpoint (already loaded).
    "ZombieButchery"
    "BetterCorpseBurning"
    "CorpseDumper"
    "B42MPZombieCorpseFix"
    "Viewpoint 42.21 Corpse Menu Fix"
    "Mulch"
    "CorpseTowing"
    "CorpseAutopsy"
    "ExerciseWithCorpses"
    "GatherFloorItems"
    "BossMan_WGQoL"
    "PersistentPlayerCorpses"
    "ZombieCorpseLimiter"
    "twistrecovery"
    "TrueCorpseStink"
  ];

  defaultSettings = {
    PVP = true;
    PauseEmpty = true;
    SaveWorldEveryMinutes = 10;
    DoLuaChecksum = false;
  };

  defaultSandbox = { };
}