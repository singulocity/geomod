-- Profiles contain asset paths so the server can select a style and clients can
-- resolve it against their own mounted content.
RFGeoMod=RFGeoMod or {}
local G=RFGeoMod
local profiles={}
local registered=false
local stock={
    label='Stock',
    dust={'particles/smokey'},
    drill='particles/smokey',
    chip='effects/fleck_cement1',
    spark='effects/yellowflare',
    bubble='effects/bubble',
    rock_sounds={
        'physics/concrete/concrete_impact_hard1.wav',
        'physics/concrete/concrete_impact_hard2.wav',
        'physics/concrete/concrete_impact_hard3.wav',
    },
}
profiles.stock=stock

function G.EffectProfileID(value)
    if type(value)=='string' and #value<=32 and value:match('^[a-z0-9_%-]+$') then return value end
    return 'stock'
end

function G.RegisterEffectProfile(id,profile)
    if G.EffectProfileID(id)=='stock' or type(profile)~='table'
        or type(profile.label)~='string' then return false end
    profiles[id]=profile
    return true
end

function G.GetEffectProfiles()
    if not registered then
        registered=true
        hook.Run('RFGeoModRegisterEffectProfiles',G.RegisterEffectProfile)
    end
    return profiles
end

function G.GetEffectProfile(id)
    return G.GetEffectProfiles()[id] or stock
end

if SERVER then
    local selection=CreateConVar('rf_geomod_effect_profile','stock',FCVAR_ARCHIVE,
        'Default profile for static GeoMod walls on maps without a geomod_effects entity.')

    function G.MapEffectProfile()
        local settings=ents.FindByClass('geomod_effects')[1]
        if IsValid(settings) then return G.EffectProfileID(settings.EffectProfile or settings.LegacyEffectProfile) end
        return G.EffectProfileID(selection:GetString())
    end

    function G.WallEffectProfile(wall)
        if IsValid(wall) and wall.BoxSource then
            local config=wall.WallKeyValues or {}
            return G.EffectProfileID(config.effects_profile)
        end
        return G.MapEffectProfile()
    end

    function G.RockImpactSound(id)
        local sounds=G.GetEffectProfile(id).rock_sounds
        if istable(sounds) and #sounds>0 then
            local path=sounds[math.random(#sounds)]
            if isstring(path) and file.Exists('sound/'..path,'GAME') then return path end
        end
        return stock.rock_sounds[math.random(#stock.rock_sounds)]
    end
else
    function G.EffectMaterial(path)
        if not isstring(path) or not file.Exists('materials/'..path..'.vmt','GAME') then return end
        local material=Material(path)
        if material:IsError() then return end
        local texture=material:GetTexture('$basetexture')
        if texture and not texture:IsError() then return material end
    end
end
