-- Static group controller and authoritative field-ray carrier.
if SERVER then AddCSLuaFile() end
ENT.Type='anim'
ENT.Base='base_anim'
ENT.PrintName='GeoMod static field'
ENT.Spawnable=false
ENT.RenderGroup=RENDERGROUP_OPAQUE
function ENT:IsDynamicWall() return false end
function ENT:Initialize()
    self:SetModel('models/hunter/blocks/cube025x025x025.mdl')
    self:SetMoveType(MOVETYPE_NONE) self:SetNoDraw(true) self:DrawShadow(false)
    self:SetSolid(SOLID_OBB) self:EnableCustomCollisions()
    if SERVER then self:SetHealth(1000000) self:SetSaveValue('m_takedamage',2) self.DoNotDuplicate=true end
end
function ENT:UpdateTransmitState() return TRANSMIT_ALWAYS end
function ENT:TestCollision(start,delta,isbox)
    if isbox then return false end
    if self.FieldVolume then return RFGeoMod.Field.Ray(self.FieldVolume,start,delta) or false end
    return false
end
function ENT:Contains(point) return self.FieldVolume and RFGeoMod.Field.Ray(self.FieldVolume,point,vector_origin)~=nil end
function ENT:CarveAt(point,normal,radius,effectOrigin)
    if not SERVER then return false end
    return RFGeoMod.Static.Carve(point,normal,radius,nil,effectOrigin or point)
end
function ENT:ResetWall() if SERVER then RFGeoMod.Static.Reset(self) end end
function ENT:SendState(ply) if SERVER then RFGeoMod.Static.Send(self,ply) end end
function ENT:OnTakeDamage(info) if SERVER then RFGeoMod.Static.Damage(self,info) end end
function ENT:OnRemove() if RFGeoMod.Static then RFGeoMod.Static.Removed(self) end end

