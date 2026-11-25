# Destructible Walls for Garry’s Mod

Blast holes through walls, floors and ceilings with any explosive, in the style of Red Faction's Geo-Mod: place destructible walls from the Sandbox tool, or let mappers mark ordinary Hammer brushes as destructible.

## Hammer
This addon also allows mappers to place `func_geomod` brushes in their maps to designate that brush as destructible. It can get lighting and otherwise act as a solid brush. When broken I have seen NPCs walk through holes though that might be non-pathfinding behavior. Nodes currently calculate as if the wall isn't there.

### Prerequisites
- All my testing/mapping was done with [Hammer++](https://ficool2.github.io/HammerPlusPlus-Website/download.html), I'd recommend it to you too! It's great for GMOD!
- Powershell
- My scripts use Python with NumPy to essentially double bake the lighting with and without the destructible brushes. I also use it to cache the geomod brushes for quick runtime fetching

In **Tools > Options > Game Configurations**, add [geomod.fgd](fgd/geomod.fgd). Tie ordinary convex wall brushes to `func_geomod` and texture their faces as usual. Set the exposed interior material, repeat and hardness on the entity. Use my [GeoMod - Full](hammer/geomod_full.cfg) profile when done to build the map with the geomod brushes.

For a map-wide effect profile, place one `geomod_effects` point entity. In **Destruction profile**, enter `stock` or the ID of a profile registered by a mounted addon.

## Destruction effects

The Tool Gun starts with **Stock**. Choose a profile from a mounted addon to use its effects on the placed wall. GeoMod's stock particles, rock sounds and cut material cover missing assets. Colliding rocks use the exposed wall material unless the profile supplies a rock material.

Static walls use `stock` by default. Server operators can set `rf_geomod_effect_profile` for maps without a `geomod_effects` entity. A Hammer map's profile applies to static walls. Tool Gun walls use their own selection.

### Register a profile

A mounted addon can register a profile from a shared autorun file. The paths are relative to `materials/` without `.vmt`, or to `sound/` with the audio extension. Supply only the assets that the profile overrides.

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

## Known limitations/issues
These are known problems that likely won't be addressed.
- Displacements are outside the supported brush format
- A test map of size 1024x1024 where the whole map is func_geomod except 128x128 units in the middle revealed cut slowdowns after about 10 cuts in the 300ms range. Though it does not appear to get exponentially worse. Results may vary per machines

## Resources used
- [Red Faction Reversed](https://github.com/rafalh/rf-reversed) to get accurate hardness and crater values
- [Reentrant Polygon Clipping by Ivan E. Sutherland and Gary W. Hodgman](https://dl.acm.org/doi/pdf/10.1145/360767.360802) more or less a direct implementation. Used for cutting
- [Constructive Solid Geometry for Polyhedral Objects by David H. Laidlaw, W. Benjamin Trumbore, and John F. Hughes](https://cs.brown.edu/people/jhughes/papers/Laidlaw-CSG-1986/paper.pdf) is THE CSG paper, referenced but not directly implemented
