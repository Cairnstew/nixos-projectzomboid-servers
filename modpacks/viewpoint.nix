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
    # VFE add-ons: content for the base mod above. Do not swap the base for
    # "Complete Vanilla Firearms Expansion" (3820580321) — it ships a different
    # Mod ID (ExtendedVanillaWeapons) and the Gunsmith/VAC/Improvised Silencers
    # VFE patches all require VFExpansion1 specifically.
    { id = "3761284354"; title = "[B42] Vanilla Firearms Expansion - STALKER pack [CLASSIC]"; } # VFExpansion2
    { id = "3762355926"; title = "[B42] Vanilla Firearms Expansion - Post '93 [CLASSIC]"; } # VFExpansion3
    { id = "2799742455"; title = "Improvised Silencers by Maxwell218"; }
    { id = "3813760573"; title = "HorseMod + Viewpoint Controls Patch"; }
    { id = "3815999052"; title = "OldPoint - Rotating Overhead Camera [B42 / Viewpoint]"; }
    # Arsenal is the successor to Recoil & ADS: it absorbs the old
    # ProjectViewpointADS mod and explicitly says to disable the older separate
    # Viewpoint weapon-handling/optics/ADS add-ons. Do not enable both.
    { id = "3816584372"; title = "Viewpoint Arsenal - ADS & Optics"; }
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

    # ── Additional vehicle content / Viewpoint vehicle bridges ──────────────
    # Filibuster adds 53 cars + 6 trailers. Its MP door/window animation sync
    # lives in the separate VASinked mod; the same Workshop item also ships an
    # optional title-screen mod, which a server does not need. More Car
    # Variants needs YAPZLib + SpecLoot and must load after the KI5 cars; the
    # Golf Cart needs damnlib. Vanilla Vehicles Replacer (KI5) is deliberately
    # absent: More Car Features says to drop vehicle replacers and use its own
    # spawn-zone settings instead.
    { id = "3683878228"; title = "[B42.19] Filibuster Rhymes' Certified Used Cars"; } # B42FRUsedCarsAnimAlpha
    { id = "3685499657"; title = "[B42.15] Vehicle Animations Sinked (Synced)"; } # Filibuster MP sync
    { id = "3812718124"; title = "[V2] More Car Variants (KI5)"; } # YAPZLib + SpecLoot
    { id = "3330401526"; title = "'85 Club Car Golf Cart"; } # damnlib
    # RVVFX is the effect framework; RVV+Viewpoint is its Viewpoint bridge.
    { id = "3788393574"; title = "Real Vehicle VFX"; }
    { id = "3814635273"; title = "RVV+Viewpoint (WIP)"; }
    # Visible Vehicle Coupling (MP) plus its Viewpoint rendering addon.
    { id = "3807182783"; title = "Visible Vehicle Coupling"; }
    { id = "3824354252"; title = "Visible Vehicle Coupling - Viewpoint Addon"; }
    # Viewpoint-specific vehicle fixes/addons (all require Viewpoint+ZombieBuddy).
    { id = "3817413313"; title = "Project Viewpoint - Immersive Driving"; }
    { id = "3815019204"; title = "Project Viewpoint - KI5 Vehicle Parts Fix"; }
    { id = "3828075703"; title = "Viewpoint - Vehicle Interior Fix (KI5 & Vanilla)"; }
    # Decay pairs with Immersive Cars: Parts Picked already in the pack.
    { id = "3495105059"; title = "Immersive Cars: Decay"; }
    # Vehicle QoL/fixes.
    { id = "3350173580"; title = "Essential Car Notifications"; }
    { id = "3805307651"; title = "Let Me Drive! - Anti-Stutter Car Controls"; }
    { id = "3007922923"; title = "Proper Vehicle Injuries for MP [B41 & B42]"; }
    { id = "3690308807"; title = "Vehicle Ground Guard [B42 SP + MP]"; }

    # ── Large / heavy vehicles ──────────────────────────────────────────────
    # W900 ships two mods: the truck (rSemiTruck) and an Oshkosh M911
    # compatibility patch (rSemiTruckhM911); enable both. W900 and LIAZ need
    # tsarslib. Trucksmith is the required framework for the RKC HEMTTs.
    { id = "3409472393"; title = "W900 Semi-Truck [B42]"; } # rSemiTruck + Oshkosh patch
    { id = "3611100835"; title = "LIAZ 300"; }
    { id = "3773998539"; title = "RVs, Heavy Duty & Trailers [B42.20–42.21]"; }
    { id = "3433311021"; title = "Road Builder"; } # Volvo FE6 dump truck + gravel roads
    { id = "3812497744"; title = "[RKC]TRUCKSMITH Vehicle"; } # framework; no vehicles itself
    { id = "3814563423"; title = "[RKC]HEMTT M977 Cargo Truck"; }
    { id = "3819092132"; title = "[RKC]HEMTT M984 Wrecker (Tow Truck)"; }
    { id = "3816356507"; title = "[RKC]HEMTT M978 Tanker Truck"; }

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
    # Apocalypse Car Engineer adds B42-native vehicle frame and vanilla-part
    # crafting, covering body/mechanical parts that Craft Engine Parts does not.
    { id = "3635856965"; title = "Better Auto Mechanics [B42.20.4+ MP+SP]"; }
    { id = "2744114761"; title = "Craft Engine Parts"; }
    { id = "3795571681"; title = "Vanilla Vehicle Parts"; }
    { id = "3631390083"; title = "Apocalypse Car Engineer Workshop - Build Cars on your own [42.20]"; }
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

    # ── Fire behaviour / realism ───────────────────────────────────────────
    # Fire Spread Control is a server-side governor: it refuses a configurable
    # share of spread-created fires and caps a blaze's radius and simultaneous
    # burning squares, so one molotov cannot roll across the map. It never
    # suppresses the initial ignition, campfires, ovens or burning corpses.
    # Sensible Fire Spread marks streets, gravel, dirt/sand, sidewalks/stone and
    # some playground rubber unflamable, so fire cannot cross a road into the
    # next block. Both are Build 42, declare no require=/incompatible=, and are
    # MP-verified (Fire Spread Control's logic is host-side; clients only need
    # it installed for the connection mod check). Deliberately NOT stacking
    # Realistic Fire Mechanics (3794202741) on top: it reimplements the same
    # material-firebreak rules and intercepts the same OnNewFire spread path,
    # and it is still a 0.7.0 test build. Better Corpse Burning's
    # corpse-to-corpse spread is independent of both.
    { id = "3775892334"; title = "Fire Spread Control"; } # FireSpreadControl
    { id = "3780363089"; title = "Sensible Fire Spread"; } # SensibleFireSpread

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

    # ── Farming / agriculture ──────────────────────────────────────────────
    # Build 42 + multiplayer, verified from each mod.info. One rebalance mod
    # (Vanilla Agriculture Fix) rather than stacking Fair Farming / Faster
    # Growth Stages. Area Tasks already handles batch sow/water/harvest, so
    # Batch Farming is deliberately omitted. Natural + Primitive Irrigation
    # are a designed pair; crop-adding mods load before the UI mods that read
    # the crop registry.
    { id = "3751370563"; title = "Vanilla Agriculture Fix"; }
    { id = "3781608503"; title = "Forever Harvestable Crops"; }
    { id = "3636824030"; title = "Force Crop Remover [B42.13.1 Fix]"; }
    { id = "3733988329"; title = "Dirt Floor Farming Fix [B42]"; }
    { id = "3782193333"; title = "Transplant Crop[42.21]"; }
    # Forestry loop: collect seeds from chopped trees, plant saplings, and grow
    # them through visible stages. No dependencies; patches ChopTree only.
    { id = "3792162621"; title = "Normal Tree Planting B42"; }
    { id = "3779625821"; title = "Fruit Farming (B42)"; }
    { id = "3787740198"; title = "BADLANDS Mycology"; }
    { id = "3763835105"; title = "Natural Irrigation"; }
    { id = "3771245646"; title = "Primitive Irrigation"; }
    { id = "3807333290"; title = "BADLANDS Greenhouse"; }
    { id = "3826228411"; title = "Fuel From Farming"; }
    { id = "3790724106"; title = "[GUI] Immersive Seed Packets [B42.20.4] [SP/MP]"; }
    { id = "3786149487"; title = "M Farming Helper B42"; }
    { id = "3470852353"; title = "[B42/41] Improved Farming Info Window"; }

    # ── Foraging / wild food ───────────────────────────────────────────────
    # All Build 42 + multiplayer. The tooltip is client-only UI; Wild Fruits
    # adds five forage definitions; Ethnobotany is a static recipe mod (scripts
    # only) that gives vanilla herbs and wild plants more uses. BADLANDS
    # Mycology already owns the mushroom niche, so no second mycology mod.
    { id = "3507997225"; title = "Foraging Tooltip Extended [B42]"; }
    { id = "2618566294"; title = "Wild Fruits"; }
    { id = "3753259986"; title = "Ethnobotany Vanilla [B42]"; }

    # ── Livestock / animal husbandry ───────────────────────────────────────
    # Build 42 + multiplayer. Feed That Animal ships an SP mod and an
    # incompatible MP replacement: only FeedThatAnimalMP is enabled. Animal
    # Barns likewise ships a safe-uninstall companion that is incompatible
    # with the main mod: only AnimalBarns is enabled. Animal Fix loads before
    # the animal-content mods it stabilises.
    { id = "3786854702"; title = "Animal Fix - Livestock Stability [B42]"; }
    { id = "3487450124"; title = "Feed That Animal!"; }
    { id = "3582024827"; title = "Better Animal Care"; }
    { id = "3568280195"; title = "Milk Them All [B42]"; }
    { id = "3807514980"; title = "[B42] Animal Barns"; }
    { id = "3787460693"; title = "Better Ranch Spawns"; }
    { id = "3808507911"; title = "Smart Animal Waste [B42+]"; }
    { id = "3640001799"; title = "Animal Collectors"; }
    { id = "3798147284"; title = "Herd Control - Quiet Animals & Better Trailers"; }

    # ── Wildlife / hunting / trapping ──────────────────────────────────────
    # Animal Sync Fix is the server+client repair for animals vanishing from
    # hutches and traps in B42 MP. Hunting Tracks Fix is server-side only and
    # re-tunes B42's track odds in memory (no vanilla file overrides).
    # Trapping split: Vanilla Trapping Fix handles recipes/XP; Better Trapping
    # is EURY's UI/placement helper (same author as Better Animal Care). They
    # touch different layers and declare no incompatibility with each other.
    { id = "3678382823"; title = "Animal Sync Fix (B42)"; }
    { id = "3790356977"; title = "Hunting Tracks [Fix]"; }
    { id = "3742961627"; title = "Vanilla Trapping Fix"; }
    { id = "3649582861"; title = "Better Trapping"; }

    # ── Beekeeping ─────────────────────────────────────────────────────────
    # ShelterHold: Beehive requires NeatUI Framework; load the framework first.
    { id = "3508537032"; title = "NeatUI Framework [B42]"; }
    { id = "3596827035"; title = "ShelterHold: Beehive"; }

    # ── Fishing ────────────────────────────────────────────────────────────
    # Better Fishing leaves vanilla balance untouched unless its sandbox
    # settings are changed; it adds the fishing status UI and reload-bait.
    # FishingActionMPFix is the server-authoritative MP repair and requires
    # ZombieBuddy (already first in this pack).
    { id = "3570485296"; title = "TwisTonFire - Better Fishing"; }
    { id = "3776009088"; title = "[B42] MP Vanilla Fishing Complete Fix"; }

    # ── Plumbing / water supply ────────────────────────────────────────────
    # Carthon's Water Pipes is the maintained network here, with its Viewpoint
    # add-on in the same Workshop item. Slayer's original Water Pipes
    # (3546314080) and LG Extended Plumbing are alternative plumbing systems,
    # deliberately not mixed in. NoCollision must load after the core; Take A
    # Bath And Shower ships its required DepthMap fix first. Both Take A Bath
    # And Shower and Immersive Water Shutoff are explicitly tested against
    # Water Pipes by the core mod author.
    { id = "3739595559"; title = "[B42] Water Pipes & Plumbing [VIEWPOINT COMPATIBLE]"; } # waterpipes + waterpipesviewpoint
    { id = "3781520357"; title = "WaterPipes No Collision"; }
    { id = "3592172476"; title = "[B42:SP/MP] Take A Bath And Shower"; } # ships DepthMap fix
    { id = "3599665197"; title = "Immersive Water Shutoff [B42MP]"; }
    { id = "3793515249"; title = "Metal Trough Plumbing"; }

    # ── Power / electricity ────────────────────────────────────────────────
    # One coherent stack: LG wires whole buildings and shares generator load;
    # Plysken Solar Revolution and BADLANDS Power are explicitly compatible
    # with it, and BADLANDS is also tested alongside Plysken. Exhaustive Power
    # Rework restores the native grid and is the mod Immersive Blackouts lists
    # as compatible; its ZombieBuddy add-on uses the ZombieBuddy already first
    # in this pack. Deliberately excluded: Generator Powered Buildings (LG says
    # run one or the other), the EPR Community/B42/Slapstick forks (hard
    # incompatible), and all Immersive Solar Arrays variants (PSR marks them
    # incompatible).
    { id = "3779562002"; title = "LG Extended Electricity"; } # ships LGExtendedElectricity + LGRealisticPowerUsage
    { id = "3725311427"; title = "Plysken Solar Revolution"; }
    { id = "3804093735"; title = "BADLANDS Power"; }
    { id = "3786970737"; title = "Exhaustive Power Rework [EPR Fork]"; } # ships ZombieBuddy add-on
    { id = "3793465866"; title = "Plysken Battery Charger"; }

    # Optional QoL/vehicle additions to the same power stack. Genset is a
    # vanilla-style generator on a trailer; Better Generator Info extends the
    # vanilla generator window (drop it first if an LG/BADLANDS custom menu
    # ever conflicts); Generator Hose overlaps LG's built-in fuel lines;
    # Battery Drain Multiplier is a sandbox balance knob.
    { id = "3803022693"; title = "Genset - Towable Generator"; }
    { id = "3576056135"; title = "Better Generator Info"; }
    { id = "3718216106"; title = "[42.20.4]Battery Drain Multiplier"; }
    { id = "3790123686"; title = "Generator Hose"; }

    # ── Gunsmithing / ammunition crafting ──────────────────────────────────
    # Gunsmith replaces the firearm repair system with weapon parts, assembly
    # and a Gunsmith skill; the same Workshop item ships a VFE add-on.
    # Vanilla Ammo Crafting also ships a VFE patch. Both add-ons require
    # VFExpansion1, which is already loaded early in this pack.
    { id = "3105394500"; title = "Gunsmith [B42 + MP]"; }
    { id = "2917021415"; title = "Vanilla Ammo Crafting"; }

    # ── Weapon progression / training ──────────────────────────────────────
    # Additive progression layers, not new gun/ammo/repair systems: Signature
    # Weapons grows a weapon through kills (with server-side sync Lua);
    # Practice Reloading trains Reloading through vanilla timed actions;
    # Training Target Shooting trains Aiming on mannequins. Deliberately not
    # adding Load It! (second ammo press), Hags/Monkey's/Universal Gun Repair
    # (second gun-repair system), Simple Silencers (second suppressor system)
    # or Madax/MFS/Gunworks (second firearm overhaul).
    { id = "3740745510"; title = "Signature Weapons"; }
    { id = "3784654830"; title = "[B42.x SP/MP] Practice Reloading"; }
    { id = "3767881622"; title = "Training Target Shooting"; }

    # Attachments UI only replaces the attachment menus; it adds no attachment
    # items, so it complements VFE's optics/bipods/slings instead of competing.
    { id = "3816324722"; title = "Attachments UI [B42]"; }

    # ── Difficulty / threat escalation ──────────────────────────────────────
    # Pressure that scales with days survived, map clearing, base activity and
    # upkeep, rather than a fixed day-one difficulty multiplier.
    { id = "3676814360"; title = "DEZ - Dynamic Evolution Z"; }
    { id = "3786750418"; title = "The Horde Is Coming"; }
    { id = "3612823857"; title = "[B42] Maintenance Driven Repair Count"; }
    { id = "3687219173"; title = "Ranged Weapon Maintenance"; }
    { id = "3778403732"; title = "Immersive Looting B42: Search & Reveal"; }
    { id = "3410729454"; title = "Proper Infected Wounds [B42.20+MP]"; }

    # ── Map tile packs (dependencies of the maps below) ─────────────────────
    { id = "3628736763"; title = "Community Tile Pack"; }
    { id = "2879745353"; title = "Melos Tiles for Miles Tilepack"; }
    { id = "2837923608"; title = "PertsPartyTiles"; }
    { id = "2852704777"; title = "Simon MDs Tiles [B41/B42]"; }
    { id = "3520263838"; title = "Extranoise's Newburbs Tiles (Official Continuation)"; }
    { id = "3694705423"; title = "Oujinjin's Tile Pack B42 Overhaul"; }
    { id = "3666137359"; title = "Rocco's Tiles"; }
    { id = "3736154771"; title = "LiuDing_Tiles"; }
    { id = "2844685624"; title = "TryHonesty's Tiles B41 & B42"; }
    { id = "3346506593"; title = "Erika's tiles"; }

    # ── Viewpoint map rendering / furniture fixes ──────────────────────────
    { id = "3813929757"; title = "Project Viewpoint: KK's General Mod Map Fix"; }
    { id = "3816419379"; title = "Project Viewpoint Map Mod Furniture - Sprite Edition"; }

    # ── Maps ───────────────────────────────────────────────────────────────
    { id = "3821291943"; title = "Jasperville [B42]"; }
    { id = "3821293600"; title = "Leavenburg [B42]"; }
    { id = "3821294884"; title = "Leavenburg Riverside Bridge [B42]"; }
    { id = "3659676359"; title = "AnruisiTown (Military Bastion)"; }
    { id = "3522517059"; title = "Safeharbor Garrison"; }
    { id = "3703704021"; title = "Chinatown B42 version"; }
    { id = "3703704638"; title = "Chinatown Expansion B42 version"; }
    { id = "3747339147"; title = "New Ellroy and Shadyside B42"; }
    { id = "3576150391"; title = "Cathaya Valley 2.0 B42 version"; }
    { id = "3449473111"; title = "[42+] [MP] Frogtown by TwinCrows"; }
    { id = "3666566299"; title = "[B42 SP/MP] BLACKSTONE - Yellowstone Survival Map"; }
    { id = "3666180085"; title = "[B42 SP/MP] Dawn Town"; }
    { id = "3496507146"; title = "[B42&MP] Fort Preston"; }
    { id = "2840889213"; title = "[B42] Chestown"; }
    { id = "3815335110"; title = "[B42] The Walking Dead - Prison"; }
    { id = "3482962418"; title = "Asakusa lake town"; }
    { id = "3580819781"; title = "Atlanta"; }
    { id = "3736155379"; title = "Begonia Town"; }
    { id = "3820667986"; title = "Blackwood (乌木镇) [B42]"; }
    { id = "3591833551"; title = "Brandenburg Beach Houses - B42.13+"; }
    { id = "3612413803"; title = "Bunker 12 [B42]"; }
    { id = "3762184916"; title = "Bunker 42"; }
    { id = "3428165477"; title = "Bunker: Last Minute Prepper (B42)"; }
    { id = "3480990544"; title = "Constown (B42)"; }
    { id = "3390753141"; title = "Daisy County B42 version"; }
    { id = "3802881424"; title = "Deer Valley Fishing Lodge 2"; }
    { id = "3476333350"; title = "EchoCreek MilitaryBase"; }
    { id = "3821285494"; title = "Ekron Castle [B42]"; }
    { id = "3673620977"; title = "Forgotten Farm Bunker (B42)"; }
    { id = "3490580478"; title = "Fort Benning B42"; }
    { id = "3747595202"; title = "Greenport, KY (B42)"; }
    { id = "3728357493"; title = "Haven Fall [B42]"; }
    { id = "3738484989"; title = "Hershel's Farm from TWDG"; }
    { id = "3545473388"; title = "Iris Eyot [B42]"; }
    { id = "3045726312"; title = "LV International Airport [B41/B42]"; }
    { id = "3644794945"; title = "Maplewood [B42]"; }
    { id = "2815966702"; title = "Rabbit Hash, KY [B42+ Update]"; }
    { id = "3388468313"; title = "RaccoonCityB42"; }
    { id = "3484263516"; title = "Raven Creek B42"; }
    { id = "3707695684"; title = "Rosewood Prison Upgrade (B42)"; }
    { id = "3756111134"; title = "Rosewood VHS & Gun Stores [B42.19]"; }
    { id = "3704429976"; title = "Towhead-Island-FOB (B42+)"; }
    { id = "3636964628"; title = "Uncle Red's Bunker B42"; }
    { id = "3673222028"; title = "West Point Military Tugboat B42"; }
    { id = "3691773420"; title = "WILDSTEEL - FORT SPIFFO"; }
    { id = "3479667649"; title = "Willowbrook Bastion!"; }
    { id = "3823399562"; title = "小音庄园 XiaoYinEstate"; }
    { id = "3495993590"; title = "榛果庄园 Hazelnut Manor"; }
  ];

  mods = [
    "ZombieBuddy"
    "Viewpoint"
    "PZVoxelStudioViewpoint"
    "ViewpointBloodFX"
    "ViewpointBloodFXAddon"
    "ProjectALifeNPCs"
    "Horse"
    "BicycleMod"
    "SkateboardMod"
    "amclub"
    "AviationCore"
    "UH-1BHelicopter"
    "ViewpointHeli"
    "VFExpansion1"
    "VFExpansion2"          # STALKER add-on (requires VFExpansion1)
    "VFExpansion3"          # Post '93 add-on (requires VFExpansion1)
    "ImprovisedSilencers"
    "ImprovisedSilencersVFEPatch"
    "HorsePatch3d"
    "OldPoint"
    "ViewpointTrueBallistics"
    "ViewpointArsenal"      # replaces ProjectViewpointADS; load after VTB + VFE
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
    "WayMoreCars"
    "LGTapeXP"
    "stanks_suicide"
    "ImmersiveBlackouts"
    "FH"
    "EQUIPMENT_UI_B42"
    "EQUIPMENT_UI"
    "dustinguished_bolt_cutters"
    "BetterSortCC"
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

    # ── Additional vehicle content ─────────────────────────────────────────
    # Filibuster before VASinked (its MP animation sync). More Car Variants
    # needs YAPZLib + SpecLoot and must load after the KI5 cars above; the
    # Golf Cart needs damnlib. Vanilla Vehicles Replacer (KI5) is deliberately
    # absent: More Car Features says to drop vehicle replacers and use its own
    # spawn-zone settings instead.
    "B42FRUsedCarsAnimAlpha"
    "VASinked"
    "MCVKI5NEW"
    "85clubMan"

    # ── Large / heavy vehicles ─────────────────────────────────────────────
    # W900 ships its own Oshkosh M911 compatibility patch: enable both mods
    # from that item. W900 and LIAZ require tsarslib (above). Trucksmith is
    # the framework the RKC HEMTTs require; enable it before them. RVs, Heavy
    # Duty & Trailers has no dependencies and includes Viewpoint support.
    # Deliberately excluded: the WIP Ford Transcontinental, the BETA Double
    # Decker Bus, Project RV Interior (mid-save/load-order warnings), and the
    # Wingsmith aircraft (separate flight framework from Aviation Core).
    "rSemiTruck"
    "rSemiTruckhM911"        # W900 <-> Oshkosh M911 patch
    "LIAZ 300"
    "RVs_HeavyDuty_Trailers"
    "DumpTruckGravelMod"
    "Trucksmith"
    "HEMTTM977Cargo"
    "HEMTTM984Wrecker"
    "HEMTTM978Tanker"

    # ── Vehicle visuals / Viewpoint bridges ────────────────────────────────
    # RVVFX -> RVV+Viewpoint; VVC -> its Viewpoint addon. ImmersiveDriving and
    # the two Viewpoint vehicle fixes require Viewpoint + ZombieBuddy (first).
    "RVVFX"
    "RVV+Viewpoint"
    "VisibleVehicleCouplingB42"
    "VVCViewpoint"
    "ImmersiveDriving"
    "ProjectViewpointKI5VehiclePartsFix"
    "ViewpointVehicleInteriorFix"

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
    # Vanilla Vehicle Parts core before its per-pack addons. APO_Engineer is
    # B42-native vehicle/parts crafting; mdrc_b42 must load after VRO.
    "better-auto-mechanics"
    "CraftEnginePartsModerate"
    "VanillaVehicleParts"
    "VVPCarModels"
    "VVPMotoModels"
    "DamnlibVanillaPartsPatch"
    "VVPHideRecipes"
    "APO_Engineer"          # vehicle frames + vanilla vehicle-part recipes
    "VehicleRepairOverhaul"
    "VehicleSalvageOverhaulB42"
    "ConsistentVehicleRepairs"
    "mdrc_b42"              # requires VehicleRepairOverhaul (loaded above)
    "Ivmakk_RestoreEngineQuality"
    "FunctionalCarLift"
    "AreaTasks"
    "AreaTasksAutoMechanics"
    "MechanicsEye"
    "GarageWorks"
    "VehicleArmorCrafting"
    "vac_engine_upgrade_kit"
    "ImmersiveCarsPicking"

    # Vehicle condition / QoL layers. Decay pairs with Parts Picked above;
    # the notifications and anti-stutter controls are client-side QoL. Vehicle
    # Ground Guard must load after every mod that adds vehicles or changes
    # vehicle mechanics, and before any vehicle-physics mod (none here).
    "ImmersiveCarsDecay"
    "EssentialCarNotifications"
    "LetMeDrive"
    "ProperVehicleInjuriesMP"
    "VehicleGroundGuard"

    # ── Gunsmithing / ammunition ───────────────────────────────────────────
    # Gunsmith core before its VFE add-on; Vanilla Ammo Crafting before its
    # VFE patch. Both add-ons require VFExpansion1, loaded earlier.
    "weapongunsmith"
    "weapongunsmith_VFE"
    "vac"
    "vac_vfe_patch"
    "RangedMaintenance"

    # ── Weapon progression / training ──────────────────────────────────────
    # Load after every gun/ammo mod so their items exist when these hook in.
    # AttachmentsUI is a menu replacement; SignatureWeapons owns its own
    # server/sync state; PracticeReloading reuses vanilla reload actions.
    "AttachmentsUI"
    "SignatureWeapons"
    "PracticeReloading"
    "TrainingTargetShooting"

    # ── Salvage / recycling ────────────────────────────────────────────────
    # Teardown produces the scrap; WasteConversion smelts it upward.
    "Teardown"
    "WasteConversion"
    "ImprovisedGlassB42"
    "KentuckyWorkstationSalvage"
    "DismantleAllElectronics"
    "TFC_RemoveDebrisMod"
    "VROSalvageConditionLock" # requires VehicleSalvageOverhaulB42 (loaded above)

    # ── Fire behaviour / realism ───────────────────────────────────────────
    # Standalone; no load-order requirement between the two. See the
    # workshopMods block above for why Realistic Fire Mechanics is not stacked.
    "FireSpreadControl"
    "SensibleFireSpread"

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

    # ── Farming / agriculture ──────────────────────────────────────────────
    # Rebalance first, then fixes, crop packs, irrigation, and finally the
    # UI mods that read every registered crop.
    "VanillaAgricultureFix"
    "ForeverHarvestableCrops"
    "DirtFloorFarmingFix"
    "ForceCropRemover"
    "vac_transplant_crop"
    "NormalTreePlantingB42" # forestry: tree seeds + sapling stages
    "FruitFarming"
    "ikag_mycology"
    "NaturalIrrigation"
    "PrimitiveIrrigation"
    "BadlandsGreenhouse"
    "FuelFromFarming"
    "ImmersiveSeedPackets"
    "MFarmingHelperB42"
    "ImprovedFarmingInfoWindow"

    # ── Foraging / wild food ───────────────────────────────────────────────
    # UI first, then the forage definitions, then the recipe-only mod.
    "Ivmakk_ForagingTooltipExtended"
    "MattSimpleAddonsFriuts"
    "EthnobotanyVanillaB42"

    # ── Livestock / animal husbandry ───────────────────────────────────────
    # Stability fix first; FeedThatAnimalMP replaces the incompatible SP mod;
    # AnimalBarns is the main mod (not its safe-uninstall companion).
    "ArcadiaAnimalFix_B42"
    "FeedThatAnimalMP"
    "EURY_ANIMALCARE"
    "Ivmakk_MilkThemAll"
    "AnimalBarns"
    "BetterRanchSpawns"
    "SmartAnimalWaste"
    "AnimalCollectors"
    "TrixHerdControl"

    # ── Wildlife / hunting / trapping ──────────────────────────────────────
    # AnimalSyncFix is server+client; HuntingTracksFix is server-only tuning;
    # VanillaTrappingFix patches recipes/XP; EURY_TRAPPING patches the trap UI
    # and placement helpers.
    "AnimalSyncFix"
    "HuntingTracksFix"
    "VanillaTrappingFix"
    "EURY_TRAPPING"

    # ── Beekeeping ─────────────────────────────────────────────────────────
    "NeatUI_Framework"
    "ShelterHold_Beehive"

    # ── Fishing ────────────────────────────────────────────────────────────
    # Better Fishing's sandbox defaults are vanilla; FishingActionMPFix needs
    # ZombieBuddy (loaded first) and owns the MP fishing action/netcode.
    "twistonfirebetterfishing"
    "FishingActionMPFix"

    # ── Plumbing / water supply ────────────────────────────────────────────
    # waterpipes -> its Viewpoint add-on -> the NoCollision add-on. Take A Bath
    # And Shower needs the DepthMap fix loaded first. Metal Trough Plumbing
    # leaves fixtures alone when another plumbing mod already supplies them.
    "waterpipes"
    "waterpipesviewpoint"
    "WaterPipesNoCollision"
    "ATakeABathAndShowerDepthMap"
    "TakeABathAndShowerNew"
    "ImmersiveWaterShutoff"
    "MetalTroughPlumbing"

    # ── Power / electricity ────────────────────────────────────────────────
    # LG core first, then its optional realistic-wattage module; BADLANDS sits
    # on top of LG's wiring; EPR restores the grid and its ZB add-on requires
    # ZombieBuddy (loaded first). PBC handles small device batteries, separate
    # from PSR's car/deep-cycle banks.
    "LGExtendedElectricity"
    "LGRealisticPowerUsage"
    "PSR"
    "BadlandsPower"
    "ExhaustivePowerRework"
    "ExhaustivePowerReworkZB"
    "PBC"

    # Optional power QoL/vehicle additions.
    "Genset"
    "BetterGeneratorInfo"
    "Battery Drain Multiplier"
    "GeneratorHose"

    # ── Difficulty / threat escalation ─────────────────────────────────────
    # Loaded last so their Lua hooks see the full mod set. DEZ and The Horde Is
    # Coming scale with days survived; mdrc_b42 and RangedMaintenance are in
    # their respective upkeep sections above.
    "DynamicEvolutionZ"
    "TheHordeIsComing"
    "ImmersiveLootingB42"
    "Proper_Infected_Wounds_b42"

    # ── Map tile packs (loaded before the maps that require them) ───────────
    "UnofficialMappersCommunityTilePack"
    "melos_tiles_for_miles_pack"
    "PertsPartyTiles"
    "simonMDsTiles"
    "ThermoNewburbs"
    "OujinjinTiles"
    "Roccos_Tiles"
    "LiuDing_Tiles"
    "TryhonestyTiles"
    "Erikas_Tiles"

    # ── Viewpoint map rendering / furniture fixes ──────────────────────────
    "PV-modmapbakefix"
    "aparosa_vpmo_RaccoonCityB42"

    # ── Maps ───────────────────────────────────────────────────────────────
    "JaspervilleB42"
    "LeavenburgB42"
    "LeavenburgBridgeB42"
    "AnruisiTown"
    "modid"
    "Chinatown B42 version"
    "Chinatown Expansion B42 version"
    "NewEllroyShadysideB42"
    "Cathaya Valley 2.0 B42 version"
    "Cathaya Valley 2.0 B42 version highway"
    "Frogtown"
    "BlackstoneMapMod"
    "dawn_town"
    "muldraughmilitarybaseas24"
    "Chestown"
    "TheWalkingDeadPrison"
    "Asakusa lake town"
    "Atlanta"
    "Begonia_Town"
    "Blackwood"
    "BrandenburgBeachHouse"
    "Bunker12"
    "Bunker42"
    "LastMinutePrepperReloadedB42"
    "Constown42"
    "Daisy County B42 version"
    "Deer Valley Fishing Lodge"
    "EchoCreek MilitaryBase"
    "EkronCastleB42"
    "ForgottenFarmBunker"
    "FortBenningB42"
    "GreenportB42"
    "HavenFall"
    "Hershel's Farm"
    "IrisEyot"
    "SimonMDLVInternationalAirport"
    "Maplewood"
    "RabbitHashKY"
    "RaccoonCityB42"
    "RavenCreekB42"
    "Rosewood Prison"
    "RosewoodVhsAndGunStoresB42"
    "Towhead-Island-FOB"
    "UncleRedsBunkerRedux"
    "WMTBoat"
    "WILDSTEEL"
    "Willowbrook Bastion! 2"
    "小音庄园XiaoYinEstate"
    "HazelnutManor"
  ];

  defaultSettings = {
    PVP = true;
    PauseEmpty = true;
    SaveWorldEveryMinutes = 10;
    DoLuaChecksum = false;
    # The public server-browser blurb (`PublicDescription=`, a real B42 key).
    # Kept on one line: PZ renders `<LINE>` as a break, and a listing reads
    # worse wrapped. ASCII only, so the .ini stays unambiguous.
    PublicDescription = "Project Viewpoint Vanilla+ - first-person Viewpoint renderer, ~390 mods (maps, vehicles, tailoring, farming, wildlife). PvP on, normal zombies.";
    # Pinned rather than derived. Several B42 map mods ship more than one map
    # folder (Chestown/Greenport keep their B41-era map alongside the B42 one),
    # so auto-detection would load both and overlap terrain. This list names only
    # the intended folders, in the authors' load order for the contiguous groups
    # (Jasperville -> bridge -> Leavenburg, Anruisi -> Safeharbor, Chinatown ->
    # expansion, Cathaya -> highway). Keep it in sync with `workshopMods`/`mods`.
    map = "Jasperville;LeavenburgBridge;Leavenburg;AnruisiTown;SafeharborGarrison;Chinatown B42 version;Chinatown Expansion B42 version;New Ellroy;Shadyside;Cathaya Valley2.0;Cathaya Valley2.0 highway;Asakusa lake town;Atlanta;Begonia_Town;Blackstone;Blackwood;BrandenburgBeachHouses;Bunker 12;Bunker 42;Chestown, KY;Constown, KY;Daisy County;DawnTown;Jester;EchoCreek MilitaryBase回音河 军事基地;EkronCastle;ForgottenFarmBunker;Fort Benning B42;Frogtown;Greenport, KY;HavenFall;Hazelnut Manor;Hershel's Farm;IrisEyot;LastMinutePrepperReloaded;lvinternationalairport;Maplewood;muldraughmilitarybaseas24;RabbitHashKY;RaccoonCity;Raven Creek B42;Rosewood Prison;RosewoodVhsAndGunStores;TheWalkingDeadPrison;Towhead-Island-FOB;Uncle Red's Bunker Redux B42;WestPoint-MilitaryTugBoat;WILDSTEEL;Willowbrook Bastion! 2026;小音庄园XiaoYinEstate;Muldraugh, KY";
  };

  defaultSandbox = { };
}