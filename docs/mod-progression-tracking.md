# Mod Progression Tracking for Viewpoint Pack

This document tracks what each mod in the `viewpoint` pack adds in terms of progression avenues - skills, recipes, items, vehicles, mechanics, etc. Use this to understand the full scope of content and plan gameplay progression.

**Pack:** `viewpoint` (Project Viewpoint Vanilla+)  
**Last Updated:** 2026-11-07  
**Total Mods:** 329 Workshop items + extras

## Progression Categories

- **Skills/XP** - New skills, skill books, XP gains
- **Recipes/Crafting** - New recipes, building options
- **Items/Equipment** - Weapons, armor, tools, consumables
- **Vehicles** - Drivable vehicles, parts, customization
- **World/Gameplay** - Events, NPCs, mechanics changes
- **QoL/UI** - Quality of life improvements (not progression content)
- **Survival/Threats** - Zombies, stealth, combat changes

---

## Core Frameworks & Libraries

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| ZombieBuddy | 3619862853 | Framework | Enables Java mods | Required by Viewpoint and other Java-based mods. No direct progression content. |
| [B42]Mod Folders | 3779201168 | Framework | Load order management | Technical mod, no progression impact. |
| that DAMN Library | 3171167894 | Library | Shared code | Used by many KI5 mods. No direct content. |
| Yet Another PZ LIbrary | 3624971238 | Library | Shared code | Common dependency. No direct content. |
| Tsar's Common Library B42 | 3402491515 | Library | Shared code | Common dependency. No direct content. |
| NeatUI Framework | 3508537032 | UI Framework | QoL only | Enables Neat Crafting/Building UIs. No progression content. |

---

## Maps & World Expansion

The pack pins `Map=` rather than deriving it, because a few B42 ports still ship
their B41-era map folder alongside the B42 one (Chestown, Greenport) and
auto-detection would load both. The pinned list names only the intended folders.
Contiguous groups keep the authors' order:

| Group | Map order |
|---|---|
| Leavenburg corridor | Jasperville → LeavenburgBridge → Leavenburg |
| Anruisi | AnruisiTown → SafeharborGarrison |
| Chinatown | Chinatown B42 version → Chinatown Expansion B42 version |
| Cathaya | Cathaya Valley2.0 → Cathaya Valley2.0 highway |
| New Ellroy | New Ellroy → Shadyside |

| Map | Workshop ID | Type | Notes |
|---|---|---|---|
| Chestown | 2840889213 | Town | B42 map folder is `Chestown, KY`; the B41 `Chestown` folder is not loaded. |
| Constown | 3480990544 | Town | Compatible with the Grapeseed cells. |
| RaccoonCityB42 | 3388468313 | City | Resident Evil-inspired, west of Muldraugh. |
| LV International Airport | 3045726312 | POI | Needs Community, Melos, Perts and Simon tiles. |
| AnruisiTown | 3659676359 | Military town | Load before Safeharbor Garrison. |
| Safeharbor Garrison | 3522517059 | Military town | Mod id is the generic `modid`; load after AnruisiTown. |
| Raven Creek B42 | 3484263516 | City | B42 port of Raven Creek. |
| Iris Eyot | 3545473388 | Town | Small island town. |
| Dawn Town | 3666180085 | Town | Dense single-cell city. |
| Haven Fall | 3728357493 | Town | Needs no tile pack. |
| Willowbrook Bastion | 3479667649 | Town | 2026 branch (`Willowbrook Bastion! 2`). |
| Daisy County | 3390753141 | County | Needs Community + Newburbs tiles; ships an items sub-mod. |
| Chinatown + Expansion | 3703704021 / 3703704638 | City | Base then expansion; needs Oujinjin/Community/Perts/Newburbs/Tryhonesty/Melos. |
| Fort Preston | 3496507146 | Military POI | MP untested by the author. |
| Begonia Town | 3736155379 | Town | Needs LiuDing + Rocco tiles. |
| Atlanta | 3580819781 | City | TWD-inspired; the separate safe-zone sub-map is not loaded. |
| Cathaya Valley 2.0 | 3576150391 | Town | Base + highway sub-map. |
| Asakusa lake town | 3482962418 | Town | Small rural town. |
| Hazelnut Manor | 3495993590 | Estate | Player-scale manor. |
| Frogtown | 3449473111 | Town | Explicit MP support. |
| Fort Benning B42 | 3490580478 | Military base | B42 port. |
| EchoCreek MilitaryBase | 3476333350 | Military POI | Mod id is `EchoCreek MilitaryBase`; map folder is Chinese. |
| Last Minute Prepper | 3428165477 | Bunker | Single-cell bunker. |
| Fort Spiffo (WILDSTEEL) | 3691773420 | Military POI | Highway intersection. |
| BLACKSTONE | 3666566299 | Wilderness | Vanilla tiles only; MP. |
| New Ellroy / Shadyside | 3747339147 | Towns | Both map folders in one mod. |
| Rosewood VHS & Gun Stores | 3756111134 | POI | Rosewood expansion. |
| Uncle Red's Bunker | 3636964628 | Bunker | Redux branch. |
| Bunker 12 | 3612413803 | Bunker | Normal branch, not the Poor Version. |
| Towhead Island FOB | 3704429976 | Military POI | Needs Community/Melos/Simon/Perts. |
| Rosewood Prison Upgrade | 3707695684 | POI | Rosewood prison. |
| Hershel's Farm | 3738484989 | POI | TWD farm. |
| Forgotten Farm Bunker | 3673620977 | Bunker | Single cell. |
| Brandenburg Beach Houses | 3591833551 | POI | Needs Melos tiles. |
| The Walking Dead Prison | 3815335110 | POI | Prison map. |
| Deer Valley Fishing Lodge 2 | 3802881424 | POI | Mod id is `Deer Valley Fishing Lodge`; needs Erika's tiles. |
| Ekron Castle | 3821285494 | POI | Fitted into vanilla Ekron. |
| Rabbit Hash, KY | 2815966702 | Town | Huge subscriber base; B42 update. |
| Greenport, KY | 3747595202 | Town | B42 map folder is `Greenport, KY`; B41 `Greenport` is not loaded. |
| Maplewood | 3644794945 | Town | Vanilla-themed, no tile pack. |
| XiaoYinEstate | 3823399562 | Estate | Vanilla assets only. |
| Blackwood | 3820667986 | Town | B42 port; needs Community tiles. |
| Bunker 42 | 3762184916 | Bunker | Military bunker. |
| Leavenburg / Jasperville | 3821293600 / 3821291943 | Towns | B42 ports; bridge needs Leavenburg. |
| West Point Military Tugboat | 3673222028 | POI | West Point river POI. |

Tile packs added for these maps: Community Tile Pack (3628736763), Melos
(2879745353), PertsPartyTiles (2837923608), Simon MDs Tiles (2852704777),
Newburbs (3520263838), Oujinjin (3694705423), Rocco's Tiles (3666137359),
LiuDing_Tiles (3736154771), TryHonesty's Tiles (2844685624) and Erika's tiles
(3346506593). The Viewpoint map-layer fix (3813929757) and map-furniture shim
(3816419379) are also enabled.

---

## First-Person & Immersion

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| Project Viewpoint | 3809306528 | Camera/Gameplay | Major gameplay change | First-person perspective overhaul. Changes how you interact with world. |
| Project Viewpoint QOL | 3811256204 | QoL | QoL improvements for FP | Hotbar cycling, loot management, auto-walk, etc. |
| Project Viewpoint - Immersive Driving | 3817413313 | Vehicles/Immersion | Vehicle immersion | FP driving improvements. |
| 6244 3D models for Viewpoint [sour_kisel] | 3810302175 | Visual | Cosmetic only | Client-side models. |
| 3d Blood VFX for Viewpoint (experimental) | 3811472160 | Visual | Cosmetic only | Client-side effects. |

---

## NPCs & World Events

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| Project A-Life [ALIFE NPCS] | 3803984183 | NPCs/World | New social interactions | Adds NPCs with potential quests/interactions. Major world progression element. |
| Project Zomboid eXpanded Helicopter Events | (via vanilla-plus context) | Events | World events | Random helicopter events. Not in viewpoint but mentioned in docs. |

---

## Combat, Weapons & Gear

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| [B42] Vanilla Firearms Expansion [CLASSIC] | 3761077099 | Weapons | New firearms, ammo | Expands vanilla gun progression. New weapons to find/craft. |
| Vanilla Outfits Expanded | 3783094058 | Clothing/Armor | New clothing options | More outfit variety, some with protection values. |
| Vanilla Gear Expanded | 3401134276 | Gear/Tools | New gear items | Additional tools/equipment to find/craft. |
| Detailed Footwear | 3270190005 | Clothing | Footwear variety | More shoe/boot options with different properties. |
| Alice's Weapon Sling | 3775549570 | Gear/QoL | Weapon carrying | QoL for weapon management, not new progression path. |
| Improvised Silencers - Build 42.20 Compatibility | 3779164273 | Weapons/Crafting | New crafting recipe | Craft silencers for weapons. Adds crafting progression. |
| dustinguished bolt cutters | 3671176591 | Tools/Crafting | Tool variant | Alternative bolt cutter. |
| Lethal Stealth | 3531611692 | Skills/Gameplay | Stealth mechanics | Alters stealth gameplay, affects approach strategies. |

---

## Skills, XP & Character Progression

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| [B42.20] Detailed Descriptions for Occupations and Traits | 3387957272 | Info/QoL | Character planning help | Shows more details about occupations/traits for build planning. |
| LG Tape XP Indicator | 3777587577 | UI/QoL | XP visibility | Shows XP gains clearly. |
| Neat Crafting & Neat Building - XP & Mod Display | 3540503606 | UI/QoL | XP visibility for recipes | Shows XP per recipe/build and which skill. |

---

## Crafting & Building

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| Neat Crafting | 3502080466 | UI/Crafting | Crafting UX improvement | Better recipe browsing. Works with Viewpoint QOL container crafting. |
| Neat Building | 3536052310 | UI/Building | Building UX improvement | Better building menu navigation. |
| Specific Loot (KI5) | 3457132019 | Loot | Affects loot tables | Changes what spawns where, affects item discovery progression. |
| Containers! | 2625625421 | Storage/World | New containers | Additional storage options in world. |
| Auto Mechanics | 3387539308 | Skills/Repair | Vehicle repair QoL | Helps with mechanic skill progression/vehicle maintenance. |
| More Damaged Objects [42MP] | 3413150945 | World | More salvage opportunities | More objects to break down/salvage. |

---

## Vehicles & Transportation

The pack has extensive KI5 vehicle mods (50+ vehicles). Each adds drivable vehicles with parts, repair needs, etc.

| Category | Count | Progression Impact | Notes |
|---|---|---|---|
| Classic/Modern Cars (60s-90s) | ~40 vehicles | Transportation progression | New vehicles to find/repair/fuel. Each is a vehicle to maintain. |
| Trucks/Vans | ~10 vehicles | Hauling/cargo | Better cargo capacity. Work vehicles. |
| Military Vehicles | ~5 vehicles | Rare vehicles | M35 series, M998, Ferret, etc. Hard to find but powerful. |
| Trailers/Campers | 3 mods (Trailers!, Campers!) | Mobile base potential | Expand vehicle utility. |
| Autotsar Motor Club B42 | 3404737883 | Vehicle parts/mods | Additional vehicle customization/parts. |
| Vehicle Seat UI (KI5) | 3501302358 | UI/QoL | Better vehicle UI. |
| Vehicle Military Zones | 3436499337 | World/Loot | Military vehicle spawns in military zones. |
| More Car Features + Spawn Zones Expansion | 3520758551 | Vehicles/World | More vehicle features and spawn variety. |
| True Cargo - Project Full HD | 3806955469 | Vehicles/Visual | Cargo model improvements. |

---

## Survival, Stealth & World

| Mod | ID | Category | Progression Impact | Notes |
|---|---|---|---|---|
| Immersive Blackouts [B42MP] | 3607686447 | Atmosphere | Darkness mechanics | Affects exploration/survival strategy at night. |
| Rain Cleans Blood [B42.20 + MP] | 2956146279 | World | Environmental cleanup | Blood washes away with rain. |
| Rebalanced Prop Moving | 2699828474 | QoL/Building | Easier furniture moving | QoL for base building, not content progression. |
| Project Parkour | 3783989538 | Movement/Skills | Movement mechanics | New movement options. Could affect exploration strategies. |
| Immersive Suicide [B42/B41] | 3426448380 | Roleplay | Alternative end states | Roleplay mechanic. |
| Horse Mod [B42.20+/MP] | 3661336777 | Transportation | Alternative mount | Another transportation option. |
| [B42.20+/MP] Bicycle! | 3461415167 | Transportation | Cheap transport | Early/mid-game transport alternative. |

---

## UI/QoL Mods (Non-Progression)

These improve UX but don't add new content/progression paths:

| Mod | ID | Purpose |
|---|---|---|
| Attachments UI [B42] | 3816324722 | Better attachment management UI |
| Equipment UI – STABLE + | 3682936016 | Equipment display improvements |
| Clean HotBar [B42] | 3461263912 | Cleaner hotbar UI |
| Reorder The Hotbar (B42+ Fixed) | 3663625294 | Hotbar rearrangement |
| Better Sorting | 2313387159 | Inventory sorting |
| [B41/42] Minimal Sidebar (Auto Hide) | 3642084851 | UI clutter reduction |
| [B42.20] Carry Visible Items In Hands [WIP] | 3749026793 | Visual feedback |
| Quick Actions | 3082160142 | Quick context actions |
| [B42] More Item Information | 3494474677 | Enhanced item tooltips |

Fuel Side Indicator is deliberately not in the pack: its Workshop id no longer
resolves, and the mod is Build 41-only (Build 42 ships the feature in vanilla).

---

## Progression Paths Overview

### Early Game (Days 1-7)
**Focus:** Scavenging, basic skills, transportation
- **Transportation:** Bicycle!, Horse Mod (if found), basic cars
- **Gear:** Vanilla Gear Expanded, Detailed Footwear provide better early loot
- **Skills:** Focus on Carpentry, Cooking, First Aid, etc.
- **QoL:** All UI mods help with inventory/loot management

### Mid Game (Weeks 1-4)
**Focus:** Base building, vehicle repair, crafting
- **Base:** Neat Building for better building UI, Containers! for storage
- **Vehicles:** Repair/maintain cars, need fuel/parts from Autotsar Motor Club
- **Weapons:** Vanilla Firearms Expansion gives ranged options
- **NPCs:** Project A-Life NPCs may appear, offering social interactions
- **Crafting:** Neat Crafting, Improvised Silencers expand recipes

### Late Game (Month+)
**Focus:** Specialization, rare vehicles, advanced base
- **Rare Vehicles:** Military vehicles (M35, Ferret) in military zones
- **Advanced Gear:** Specialized equipment from expanded loot tables (Specific Loot)
- **Stealth/Movement:** Lethal Stealth, Project Parkour change playstyle
- **Social:** Deeper interactions with Project A-Life NPCs

---

## Tracking Checklist

Use this to track your progression through the modded content:

- [ ] **Frameworks loaded** - ZombieBuddy + Viewpoint working
- [ ] **Character built** - Planned occupation/traits using detailed descriptions
- [ ] **First vehicle** - Found and repaired any drivable vehicle
- [ ] **Base established** - Using improved building/crafting UI
- [ ] **Firearms acquired** - Found/crafted from Vanilla Firearms Expansion
- [ ] **NPC interaction** - Encountered Project A-Life NPCs
- [ ] **Stealth/movement mastered** - Tried Lethal Stealth or Parkour
- [ ] **Rare vehicle** - Acquired military/special vehicle
- [ ] **Mobile base** - Used Trailers/Campers

---

## Notes for Server Admins

- **Client-side mods:** Project Viewpoint, Viewpoint QOL, all UI mods are client-side only
- **Shared mods:** Most content mods (vehicles, weapons, NPCs, etc.) need to be on server for all players
- **ZombieBuddy:** Required on both client and server for Java mods
- **Load order:** Critical - ZombieBuddy first, then Viewpoint, then Viewpoint QOL, then NeatUI Framework, then Neat mods, then content

See `docs/host-recipes.md` and the pack definition in `modpacks/viewpoint.nix` for exact configuration.
