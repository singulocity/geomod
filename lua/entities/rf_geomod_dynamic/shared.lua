ENT.Type = 'anim'
ENT.Base = 'base_anim'
ENT.PrintName = 'GeoMod movable wall'
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.Low, ENT.High = Vector(-32,-256,0),Vector(32,256,256)

include('rf_geomod/geometry.lua')
include('rf_geomod/bsp.lua')

local function corner(value,default)
    if isvector(value) then return Vector(value.x,value.y,value.z) end
    local x,y,z=tostring(value or ''):match('^%s*([^%s]+)%s+([^%s]+)%s+([^%s]+)%s*$')
    x,y,z=tonumber(x),tonumber(y),tonumber(z)
    if not x or not y or not z or x~=x or y~=y or z~=z then return Vector(default.x,default.y,default.z) end
    return Vector(x,y,z)
end

local function materialPath(value,default)
    local path=string.Trim(tostring(value or '')):gsub('\\','/'):gsub('^materials/',''):gsub('%.vmt$','')
    return path~='' and path or default
end

function ENT:ApplyWallConfiguration(config)
    local low=corner(config.mins,Vector(-32,-256,0))
    local high=corner(config.maxs,Vector(32,256,256))
    -- Reject inverted/degenerate bounds instead of silently making different
    -- geometry from what the mapper entered. Existing maps retain their defaults.
    for _,axis in ipairs({'x','y','z'}) do
        if high[axis]-low[axis]<1 or math.abs(low[axis])>16384 or math.abs(high[axis])>16384 then
            ErrorNoHalt('[GeoMod] Invalid bounds; using the original wall dimensions\n')
            low,high=Vector(-32,-256,0),Vector(32,256,256) break
        end
    end
    local surface=materialPath(config.surface_material,'dev/dev_measurewall01a')
    local interior=materialPath(config.cut_material,'concrete/concretewall036a')
    local surfaceRepeat=math.Clamp(tonumber(config.surface_repeat) or 128,1,8192)
    local cutRepeat=math.Clamp(tonumber(config.cut_repeat) or 128,1,8192)
    local changed=not self.WallConfigured or self.BoxLow~=low or self.BoxHigh~=high or
        self.SurfaceMaterialName~=surface or self.CutMaterialName~=interior or
        self.SurfaceRepeat~=surfaceRepeat or self.CutRepeat~=cutRepeat
    -- BoxLow/BoxHigh describe a box source (toolgun walls); Low/High are the
    -- current geometry bounds used for collision and render bounds.
    self.BoxLow,self.BoxHigh=low,high
    -- A loaded brush source owns Low/High. Every state update reapplies this
    -- configuration; resetting a map wall to the default box here moved its
    -- render bounds to the map origin, so the wall vanished once off-screen.
    if not self.BrushSourceModel then self.Low,self.High=low,high end
    self.Hardness=RFGeoMod.ClampHardness(config.hardness)
    self.WeightMultiplier=RFGeoMod.ClampWeightMultiplier(config.weight_multiplier)
    self.SurfaceMaterialName,self.CutMaterialName=surface,interior
    self.SurfaceRepeat,self.CutRepeat=surfaceRepeat,cutRepeat
    if changed then self.WallMaterialNames={surface,interior} end
    self.WallConfigured=true
    return changed
end

function ENT:LoadWallSource(model)
    if self.SeedPieces then
        self.InitialPieces=self.SeedPieces
        self.WallMaterialNames=self.SeedMaterials
        self.Low,self.High=RFGeoMod.Bounds(self.InitialPieces)
        self.BrushSourceModel=nil
        return true
    end
    -- Map walls come from compiled func_geomod brushes. Toolgun walls
    -- (RF-071) use a box source; a missing brush is still an error for maps.
    if not model or model=='' then
        if not self.BoxSource then return false,'GeoMod requires a compiled brush source.' end
        local box=RFGeoMod.Box(self.BoxLow,self.BoxHigh)
        if not box then return false,'Invalid GeoMod box dimensions.' end
        self.InitialPieces={box}
        self.WallMaterialNames={self.SurfaceMaterialName,self.CutMaterialName}
        self.BrushSourceModel=nil
        return true
    end
    local source,err=RFGeoMod.ReadBrushModel(model,self.CutMaterialName)
    if not source then return false,err end
    self.InitialPieces=source.pieces
    self.Low,self.High=source.low,source.high
    self.WallMaterialNames=source.materials
    self.BrushSourceModel=model
    -- Moving chunks of a map brush use prop lighting, not its baked lightmaps.
    if CLIENT and not self.DynamicWall then self.SourceLightmaps=RFGeoMod.ReadLightmaps(model) end
    return true
end

local function coordinates(v) return {v.x,v.y,v.z} end

function RFGeoMod.PackMovableSeed(pieces,materials)
    local data={pieces={},materials=materials}
    for _,piece in ipairs(pieces) do
        local records={}
        for _,f in ipairs(piece.faces) do
            local row={points={},mat=f.mat,nodraw=f.nodraw}
            for i,p in ipairs(f.points) do row.points[i]=coordinates(p) end
            if f.uv then
                row.uv={coordinates(f.uv.u),coordinates(f.uv.v),f.uv.uo,f.uv.vo,f.uv.width,f.uv.height}
            end
            records[#records+1]=row
        end
        data.pieces[#data.pieces+1]=records
    end
    local encoded=util.Compress(util.TableToJSON(data))
    if encoded and #encoded<44000 then return encoded end
end

function RFGeoMod.UnpackMovableSeed(encoded)
    local data=util.JSONToTable(util.Decompress(encoded))
    if not data then return end
    local pieces={}
    for _,source in ipairs(data.pieces) do
        local faces={}
        for _,f in ipairs(source) do
            local points={}
            for i,p in ipairs(f.points) do points[i]=Vector(unpack(p)) end
            local uv=f.uv and {u=Vector(unpack(f.uv[1])),v=Vector(unpack(f.uv[2])),
                uo=f.uv[3],vo=f.uv[4],width=f.uv[5],height=f.uv[6]}
            faces[#faces+1]={points=points,mat=f.mat,nodraw=f.nodraw,uv=uv}
        end
        local piece=RFGeoMod.Prepare(faces)
        if not piece then return end
        pieces[#pieces+1]=piece
    end
    return pieces,data.materials
end

function ENT:TestCollision(start,delta,isbox,extents)
    -- Delegate to the actual VPhysics union, including hull bevels and start-solid
    -- handling. Lua plane expansion was only conservative and did not reproduce
    -- Source player movement traces correctly around concave crater edges.
    return true
end

function ENT:IsDynamicWall() return self.DynamicWall==true end

-- Keep each movable collider below the hull count that stalled VPhysics in
-- the maximum-size toolgun wall regression. Static triangle meshes are separate.
local MAX_COLLISION_HULLS=192

local function collisionHull(piece)
    if piece.physicsVertices~=nil then return piece.physicsVertices end
    local vertices,seen={},{}
    -- Match the static collider's 1/32-unit precision. Repeated cuts can
    -- otherwise feed nearly coincident points and flat slivers to VPhysics.
    for _,p in ipairs(piece.vertices) do
        local x,y,z=math.Round(p.x*32),math.Round(p.y*32),math.Round(p.z*32)
        local key=x..':'..y..':'..z
        if not seen[key] then
            seen[key]=true
            vertices[#vertices+1]=Vector(x/32,y/32,z/32)
        end
    end
    piece.physicsVertices=false
    if #vertices<4 then return false end

    local origin=vertices[1]
    local edge,edgeLength=vector_origin,0
    for i=2,#vertices do
        local delta=vertices[i]-origin
        local length=delta:LengthSqr()
        if length>edgeLength then edge,edgeLength=delta,length end
    end
    local plane,area=vector_origin,0
    for i=2,#vertices do
        local cross=edge:Cross(vertices[i]-origin)
        local length=cross:LengthSqr()
        if length>area then plane,area=cross,length end
    end
    if area>0 then
        plane:Normalize()
        for i=2,#vertices do
            if math.abs(plane:Dot(vertices[i]-origin))>=1/32 then
                piece.physicsVertices=vertices
                return vertices
            end
        end
    end
    return false
end

local function collisionHulls(pieces,checkpoint)
    local hulls={}
    for _,piece in ipairs(pieces) do
        local hull=collisionHull(piece)
        if hull then hulls[#hulls+1]=hull end
        if checkpoint then checkpoint() end
    end
    return hulls
end

function ENT:PrepareCollision(pieces,checkpoint)
    if #pieces==0 then return {} end
    local hulls=collisionHulls(pieces,checkpoint)
    if #hulls>MAX_COLLISION_HULLS then
        hulls=collisionHulls(RFGeoMod.MergeConvexPieces(pieces,checkpoint),checkpoint)
        if #hulls>MAX_COLLISION_HULLS then return false,'collision_limit' end
    end
    if #hulls==0 then return false,'empty_collision' end
    return hulls
end

function ENT:BuildPhysics(pieces,checkpoint,hulls)
    if SERVER and self:IsPlayerHolding() then return false,'held' end
    if #pieces==0 then
        self:PhysicsDestroy() self:SetSolid(SOLID_NONE)
        return true
    end
    if not hulls then
        local failure
        hulls,failure=self:PrepareCollision(pieces,checkpoint)
        if not hulls then return false,failure end
    end
    if checkpoint then checkpoint() end
    if SERVER and self:IsPlayerHolding() then return false,'held' end
    local dynamic=self:IsDynamicWall()
    -- Rebuilding a moving wall must not stop or teleport it.
    local old=self:GetPhysicsObject()
    local velocity,angular,motion
    if dynamic and SERVER and IsValid(old) then
        velocity,angular,motion=old:GetVelocity(),old:GetAngleVelocity(),old:IsMotionEnabled()
    end
    local pos,ang=self:GetPos(),self:GetAngles()
    self:SetSolid(SOLID_VPHYSICS)
    if not self:PhysicsInitMultiConvex(hulls,'concrete') then return false end
    if dynamic then
        if self.Low and self.High and #pieces>0 then self.Low,self.High=RFGeoMod.Bounds(pieces) end
        if SERVER then self:SetMoveType(MOVETYPE_VPHYSICS) end
    else
        self:SetMoveType(MOVETYPE_NONE)
    end
    self:ConfigureBounds()
    local physics = self:GetPhysicsObject()
    if not IsValid(physics) then return false end
    physics:SetPos(pos) physics:SetAngles(ang)
    if dynamic and SERVER then
        local surface
        surface,self.PhysicsSurfaceData=RFGeoMod.MaterialPhysicsSurface(self.CutMaterialName)
        physics:SetMaterial(surface)
        physics:SetMass(RFGeoMod.HardnessMass(RFGeoMod.Volume(pieces),self.Hardness,self.WeightMultiplier))
        if motion==nil then motion=not self.FrozenWall end
        physics:EnableMotion(motion)
        if motion then
            physics:Wake()
            if velocity then physics:SetVelocity(velocity) physics:AddAngleVelocity(angular) end
        end
    else
        physics:EnableMotion(false)
    end
    return true
end

function ENT:ConfigureBounds()
    self:SetCollisionBounds(self.Low,self.High)
    self:EnableCustomCollisions(true)
    if CLIENT then self:SetRenderBounds(self.Low,self.High) end
end
