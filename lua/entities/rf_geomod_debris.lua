AddCSLuaFile()
ENT.Type='anim'
ENT.Base='base_anim'
ENT.PrintName='Temporary GeoMod rock'
ENT.Spawnable=false
ENT.RenderGroup=RENDERGROUP_TRANSLUCENT
ENT.DoNotDuplicate=true

function ENT:SetupDataTables()
    self:NetworkVar('Float',0,'RockRadius')
    self:NetworkVar('Float',1,'FadeAt')
    self:NetworkVar('Int',0,'RockSeed')
    self:NetworkVar('String',0,'RockMaterial')
end

if SERVER then
    function ENT:Initialize()
        self:SetModel('models/hunter/misc/sphere025x025.mdl')
        local radius=math.Clamp(self:GetRockRadius(),2,10)
        self:SetRockRadius(radius)
        self:PhysicsInitSphere(radius,'concrete')
        self:SetMoveType(MOVETYPE_VPHYSICS) self:SetSolid(SOLID_VPHYSICS)
        self:SetCollisionBounds(Vector(-radius,-radius,-radius),Vector(radius,radius,radius))
        self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
        self:SetFadeAt(CurTime()+math.Rand(1,4))
        self.RFCanHurt=radius>=6
        self.RFPreviousPosition=self:GetPos()
        local phys=self:GetPhysicsObject()
        if IsValid(phys) then phys:SetMass(math.Clamp(radius^3*0.004,0.2,4)) phys:SetBuoyancyRatio(0) phys:Wake() end
    end

    function ENT:BeginFade()
        self:SetFadeAt(math.min(self:GetFadeAt(),CurTime()))
        self.RFCanHurt=false
    end

    function ENT:PhysicsCollide(data,phys)
        -- Catch solid targets before a bounce loses the incoming velocity.
        -- Defer damage: a breakable can remove/spawn physics in its handler.
        self:DamageContact(data.HitEntity,data.HitPos,data.OurOldVelocity)
        -- CollisionData points out of this rock toward the other surface,
        -- opposite to a world TraceResult normal (floor contact is -Z).
        if data.HitNormal.z<=-0.7 then
            self:BeginFade()
        end
        if data.Speed>80 and (self.RFNextImpact or 0)<CurTime() then
            self.RFNextImpact=CurTime()+0.12
            self:EmitSound(RFGeoMod.RockImpactSound(self.EffectProfile),65,100,0.6)
        end
    end

    function ENT:DamageContact(target,position,velocity)
        if not self.RFCanHurt or not IsValid(target) or target:IsWorld() or target==self
            or target:GetClass()=='rf_geomod_debris' then return end
        if target:IsPlayer() and not target:Alive() then return end
        self.RFCanHurt=false
        local amount=0.5*(velocity:Length()/40)*(self:GetRockRadius()/40)*RFGeoMod.DebrisDamage:GetFloat()
        if amount<=0 then return end
        timer.Simple(0,function()
            if not IsValid(target) then return end
            local info=DamageInfo() info:SetDamage(amount) info:SetDamageType(DMG_CRUSH)
            info:SetAttacker(game.GetWorld()) info:SetInflictor(IsValid(self) and self or game.GetWorld())
            info:SetDamagePosition(position)
            target:TakeDamageInfo(info)
        end)
    end

    function ENT:CheckEntityContact(start,finish,velocity)
        if not self.RFCanHurt then return end
        local r=self:GetRockRadius()
        local tr=util.TraceHull({start=start,endpos=finish,mins=Vector(-r,-r,-r),maxs=Vector(r,r,r),
            filter=function(e) return e~=self and e:GetClass()~='rf_geomod_debris' end,mask=MASK_SHOT_HULL})
        self:DamageContact(tr.Entity,tr.HitPos,velocity)
    end

    function ENT:Think()
        local now=CurTime()
        if now>self:GetFadeAt()+1 then self:Remove() return end
        local phys=self:GetPhysicsObject()
        if not IsValid(phys) then self:Remove() return end
        local pos=self:GetPos()
        self:CheckEntityContact(self.RFPreviousPosition or pos,pos,phys:GetVelocity())
        self.RFPreviousPosition=pos
        if phys:IsAsleep() then self:BeginFade() end
        self:NextThink(now+0.03) return true
    end
    function ENT:OnRemove() end
    hook.Add('PhysgunPickup','rf_geomod_debris',function(_,e) if e:GetClass()=='rf_geomod_debris' then return false end end)
    hook.Add('CanTool','rf_geomod_debris',function(_,tr) if IsValid(tr.Entity) and tr.Entity:GetClass()=='rf_geomod_debris' then return false end end)
    return
end

-- Consistent outward shell topology. A concave random face must not be
-- flipped independently based on its distance from the origin.
local faces={{1,7,3},{1,5,7},{1,3,4},{1,4,2},{1,2,6},{1,6,5},
             {8,2,4},{8,6,2},{8,7,5},{8,5,6},{8,4,3},{8,3,7}}
local materials={}
local lightNormals={Vector(1,0,0),Vector(-1,0,0),Vector(0,-1,0),Vector(0,1,0),Vector(0,0,1),Vector(0,0,-1)}
local function rockMaterial(path)
    if materials[path] then return materials[path] end
    local original=RFGeoMod.EffectMaterial(path)
    local texture=original and original:GetTexture('$basetexture')
    local name=texture and texture:GetName() or 'concrete/concretewall036a'
    local mat=CreateMaterial('rf_geomod_rock_'..util.CRC(path),'VertexLitGeneric',{
        ['$basetexture']=name,['$model']='1',['$vertexcolor']='1',['$vertexalpha']='1',
        ['$translucent']='1',['$nocull']='0'})
    materials[path]=mat return mat
end

function ENT:BuildRockMesh()
    local seed,radius=self:GetRockSeed(),self:GetRockRadius()
    if seed==0 or radius<=0 then return end
    local points={}
    for i=0,7 do
        local p={}
        for j=0,2 do
            local sign=bit.band(i,bit.lshift(1,j))~=0 and 1 or -1
            p[j+1]=sign*util.SharedRandom('rf_geomod_rock_'..i..'_'..j,radius*0.2,radius*1.8,seed)
        end
        points[i+1]=Vector(unpack(p))
    end
    local triangles={}
    for _,face in ipairs(faces) do
        local a,b,c=points[face[1]],points[face[2]],points[face[3]]
        local normal=(b-a):Cross(c-a):GetNormalized()
        local axis=math.abs(normal.z)>0.7 and Vector(1,0,0) or normal:Cross(vector_up):GetNormalized()
        local other=normal:Cross(axis)
        -- Source IMesh uses the opposite order to the outward cross-product
        -- normal, just like the existing GeoMod wall renderer.
        for _,p in ipairs({a,c,b}) do triangles[#triangles+1]={pos=p,normal=normal,u=p:Dot(axis)/64,v=p:Dot(other)/64} end
    end
    self.RFMesh=Mesh() self.RFMesh:BuildFromTriangles(triangles)
    self.RFMeshSeed=seed
    self:SetRenderBounds(Vector(-radius*3,-radius*3,-radius*3),Vector(radius*3,radius*3,radius*3))
    return triangles
end

function ENT:GetRockRenderMaterial()
    return rockMaterial(self:GetRockMaterial())
end

function ENT:DrawRockMesh(transform)
    cam.PushModelMatrix(transform)
    -- The fade material is translucent, so it does not normally write depth.
    -- Establish the nearest surface first to keep rear triangles from drawing
    -- over the front of this closed rock, including while it fades.
    render.OverrideColorWriteEnable(true,false)
    render.OverrideDepthEnable(true,true)
    self.RFMesh:Draw()
    render.OverrideDepthEnable(false,false)
    render.OverrideColorWriteEnable(false,false)
    self.RFMesh:Draw()
    cam.PopModelMatrix()
end

function ENT:DrawTranslucent()
    if not self.RFMesh then self:BuildRockMesh() end
    if not self.RFMesh then return end
    local alpha=math.Clamp(self:GetFadeAt()+1-CurTime(),0,1)
    if alpha<=0 then return end
    local transform=Matrix() transform:SetTranslation(self:GetPos()) transform:SetAngles(self:GetAngles())
    -- IMesh does not inherit model blend modulation. Drive the actual shader
    -- alpha; render.SetBlend alone leaves these rocks opaque until removal.
    local material=self:GetRockRenderMaterial()
    material:SetFloat('$alpha',alpha)
    -- IMesh otherwise inherits the last model's lightbox (sometimes black
    -- after a prop or NPC is removed). Sample lighting at this fragment.
    if not self.RFLightAt or CurTime()>=self.RFLightAt then
        self.RFLights={}
        for i,normal in ipairs(lightNormals) do self.RFLights[i]=render.ComputeLighting(self:GetPos(),normal) end
        self.RFLightAt=CurTime()+0.1
    end
    for i,light in ipairs(self.RFLights) do render.SetModelLighting(i-1,light.x,light.y,light.z) end
    render.SetMaterial(material)
    self:DrawRockMesh(transform)
    render.ResetModelLighting(1,1,1)
    material:SetFloat('$alpha',1)
end

function ENT:OnRemove()
    if self.RFMesh then self.RFMesh:Destroy() self.RFMesh=nil end
end
