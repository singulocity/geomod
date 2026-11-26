# Destructible Walls for Garry’s Mod

Destroy walls in the style of Red Faction's Geo-Mod engine: place destructible walls with the tool gun, or let mappers mark ordinary map brushes as destructible. Blow them up or ram into them!

## Hammer
Assign `func_geomod` to brushes into your maps to designate that brush as destructible. It can get lighting and otherwise act as a solid brush. When broken I have seen NPCs walk through holes though that might be non-pathfinding behavior. AI Nodes currently calculate as if the wall isn't there.

### Prerequisites
- All my testing/mapping was done with [Hammer++](https://ficool2.github.io/HammerPlusPlus-Website/download.html), I'd recommend it to you too! It's great for GMOD!
- Powershell
- My scripts use Python 3.15 with NumPy to essentially double bake the lighting with and without the destructible brushes. I also use Python to cache the geomod brushes for quick runtime fetching

In **Tools > Options > Game Configurations**, add [geomod.fgd](fgd/geomod.fgd). Tie ordinary convex wall brushes to `func_geomod` and texture their faces as usual. Set the exposed interior material, repeat and hardness on the entity.

For a map-wide effect profile, place one `geomod_effects` point entity. In **Destruction profile**, enter `stock` or the ID of a profile registered by a mounted addon.

Use my [GeoMod - Full](hammer/geomod_full.cfg) profile when done to build the map. You can import it by going to **File > Run Map... > Expert... > Edit next to the Configurations > Import** and then select the geomod_full.cfg file. You should see **GeoMod - Full** listed. Run your map with that, it will build the map normally, then bake the lighting twice, and finally run a small version of GMOD so it can cache the GeoMod brushes for quick retrieval later that you can include in your map. It's stored in your GMOD's `data/rf-geomod-cache/` folder.

## Destruction effects

The tool gun starts with **Stock**. Choose a profile from a mounted addon to use its effects on the placed wall. GeoMod falls back to stock particles and Half-Life 2's first scorch mark when a profile asset is missing. Temporary debris uses the exposed inside material for its collision sounds, with concrete as the fallback for materials without a valid surface property. Profiles can override the debris texture with `rock_material` and the impact sounds with `rock_sounds`.

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
        scorch = "my_addon/scorch",
        rock_material = "my_addon/rock",
        rock_sounds = {"my_addon/rock_impact.wav"},
    })
end)
```

Use a translucent `UnlitGeneric` scorch material with `$decal` enabled and
a writable `$basetexturetransform`.

## Known limitations/issues
These are known problems that likely won't be addressed.
- Displacements are outside the supported brush format
- A test map of size 1024x1024 where the whole map is func_geomod except 128x128 units in the middle revealed cut slowdowns after about 10 cuts in the 300ms range. Though it does not appear to get exponentially worse. Results may vary per machines
- The dynamically made GeoMod walls (so the ones cut off of static walls, or from the tool gun) have a cap of 192 collision hull. This is to prevent a crash. So eventually those types of walls refuse to cut further. The static walls don't have this problem

## Resources used
- [Red Faction Reversed](https://github.com/rafalh/rf-reversed) to get accurate hardness and crater values
- [Reentrant Polygon Clipping by Ivan E. Sutherland and Gary W. Hodgman](https://dl.acm.org/doi/pdf/10.1145/360767.360802) more or less a direct implementation. Used for cutting
- [Constructive Solid Geometry for Polyhedral Objects by David H. Laidlaw, W. Benjamin Trumbore, and John F. Hughes](https://cs.brown.edu/people/jhughes/papers/Laidlaw-CSG-1986/paper.pdf) is THE CSG paper, referenced but not directly implemented
