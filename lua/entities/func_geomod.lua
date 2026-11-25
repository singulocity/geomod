-- Hammer source brush. Connected authored solids feed world-space static fields.
if CLIENT then return end
ENT.Type='brush'
ENT.Base='base_brush'
ENT.PrintName='Destructible GeoMod brush'
function ENT:KeyValue(key,value)
    key=string.lower(key)
    if key=='cut_material' or key=='cut_repeat' or key=='hardness' or key=='disable_physgun' or key=='disable_tools' then
        self.WallKeyValues=self.WallKeyValues or {} self.WallKeyValues[key]=value
        return true
    end
end
function ENT:Initialize()
    local config=self.WallKeyValues or {}
    RFMapProtection.Apply(self,config)
    RFGeoMod.Static.Register(self)
end
