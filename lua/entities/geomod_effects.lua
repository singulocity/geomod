-- Optional map-wide effect selection for static GeoMod walls.
if CLIENT then return end
ENT.Type='point'
ENT.Base='base_point'
ENT.PrintName='GeoMod destruction effects'

function ENT:KeyValue(key,value)
    key=key:lower()
    if key=='destruction_profile' then
        self.EffectProfile=RFGeoMod.EffectProfileID(value)
    elseif key=='effects_profile' then
        self.LegacyEffectProfile=RFGeoMod.EffectProfileID(value)
    else
        return
    end
    return true
end
