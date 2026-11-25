# GeoMod for Garry’s Mod

Copy this folder to `garrysmod/addons/geomod` and start a fresh game session.
GeoMod uses the base game's assets and works on its own.

## Sandbox

Open **Tools > GeoMod > GeoMod Wall**. Left-click to place a wall and
right-click an existing GeoMod wall to copy its materials, hardness and effects.
Set the wall size, hardness and frozen state before placing it. The outside
defaults to `brick/brickwall003a` and the interior to
`concrete/concretewall036a`. Use either **Browse** button to choose a mounted
material or enter its path directly. On multiplayer servers, use materials
mounted on the server and shared with all players.

Blast the wall with an explosive such as the stock RPG. Standard Sandbox undo
and cleanup apply to placed walls. The admin command `rf_geomod_reset` restores
GeoMod walls on the current map.

## Shadows

GeoMod walls and destructible map surfaces are drawn by GeoMod, so the engine's
dynamic shadows cannot land on them. GeoMod draws those shadows itself. Like the
engine, it lets every nearby model entity cast unless that entity disables its shadow.
That includes players, NPCs, props, ragdolls, vehicles and pickups. Shadows follow the
map's `shadow_control` direction, color and distance. Entities can extend their reach
with `ent.RFShadowDistance`, as hovering pickups do.
Each player can turn this off with `rf_geomod_shadows 0`. It also follows `r_shadows`.
`rf_geomod_shadows_resolution` (64 to 512, default 256) sets pixels per shadow, and
`rf_geomod_shadows_supersample` (default 1) anti-aliases the edges, and `rf_geomod_shadows_blur`
(0 to 8, default 0.3) softens them slightly.

## Destruction effects

The Tool Gun starts with **Stock**. Choose a profile from a mounted addon
to use its effects on the placed wall.
GeoMod's stock particles, rock sounds and cut material cover missing assets.
Colliding rocks use the exposed wall material unless the profile supplies a
rock material.

Static walls use `stock` by default. Server operators can set
`rf_geomod_effect_profile` for maps without a `geomod_effects` entity.
A Hammer map's profile applies to static walls. Tool Gun walls use their own selection.

### Register a profile

A mounted addon can register a profile from a shared autorun file. The paths
are relative to `materials/` without `.vmt`, or to `sound/` with the audio
extension. Supply only the assets that the profile overrides.

```lua
hook.Add("RFGeoModRegisterEffectProfiles", "my_addon", function(register)
    register("my_addon", {
        label = "My Addon",
        dust = {"my_addon/dust_00", "my_addon/dust_01"},
        drill = "my_addon/drill_dust",
        chip = "my_addon/concrete_chip",
        spark = "my_addon/spark",
        bubble = "my_addon/bubble",
        rock_material = "my_addon/rock",
        rock_sounds = {"my_addon/rock_impact.wav"},
    })
end)
```

## Hammer

In **Tools > Options > Game Configurations**, add [geomod.fgd](fgd/geomod.fgd)
alongside `garrysmod.fgd`. Tie ordinary convex wall brushes to
`func_geomod` and texture their faces as usual. Set the exposed interior
material, repeat and hardness on the entity. Keep the world shell structural
and use the entity for the sections you want players to destroy. Displacements
are outside the supported brush format. Compile any custom map with Hammer's
normal VBSP, VVIS and VRAD steps. The compiled map needs GeoMod mounted on the
server for destructible walls and can generate its cache on first load.

For a map-wide effect profile, place
one `geomod_effects` point entity. In **Destruction profile**, enter `stock`
or the ID of a profile registered by a mounted addon.
