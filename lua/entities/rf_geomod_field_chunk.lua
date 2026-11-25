-- Rebuilt physical/render area; geometry remains in the map's world frame.
if SERVER then AddCSLuaFile() end
ENT.Type='anim'
ENT.Base='base_anim'
ENT.PrintName='GeoMod field chunk'
ENT.Spawnable=false
ENT.RenderGroup=RENDERGROUP_OPAQUE
function ENT:Initialize()
    self:SetModel('models/hunter/blocks/cube025x025x025.mdl')
    self:SetMoveType(MOVETYPE_NONE) self:SetSolid(SOLID_NONE) self:DrawShadow(false)
    if SERVER then self:SetHealth(1000000) self:SetSaveValue('m_takedamage',2) self.DoNotDuplicate=true end
end
function ENT:UpdateTransmitState() return TRANSMIT_ALWAYS end
function ENT:TestCollision(_,_,isbox) return isbox and true or false end
function ENT:OnTakeDamage(info)
    if SERVER then local wall=RFGeoMod.WallFor(self) if IsValid(wall) then RFGeoMod.Static.Damage(wall,info) end end
end
function ENT:Draw() if RFGeoMod.FieldRender then RFGeoMod.FieldRender.Draw(self) end end
function ENT:OnRemove() if CLIENT and RFGeoMod.FieldRender then RFGeoMod.FieldRender.Clear(self) end end
