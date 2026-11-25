# Destructible Walls for Garry’s Mod

Blast holes through walls, floors and ceilings with any explosive, in the style of Red Faction's Geo-Mod: place destructible walls from the Sandbox tool, or let map makers mark ordinary Hammer brushes as destructible.

## How To Use In Game

Open **Tools > GeoMod > GeoMod Wall**. Left-click to place a wall and
right-click an existing GeoMod wall to copy its materials, hardness and effects.
Set the wall size, hardness and frozen state before placing it. The outside
defaults to `brick/brickwall003a` and the interior to
`concrete/concretewall036a`. Use either **Browse** button to choose a mounted
material or enter its path directly.

Blast the wall with an explosive such as the stock RPG. Standard Sandbox undo
and cleanup apply to placed walls. The admin command `rf_geomod_reset` restores
GeoMod walls on the current map.

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
