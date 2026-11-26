AddCSLuaFile('shared.lua')
AddCSLuaFile('cl_init.lua')
AddCSLuaFile('rf_geomod/geometry.lua')
AddCSLuaFile('rf_geomod/bsp.lua')
AddCSLuaFile('rf_geomod/lightmaps.lua')
AddCSLuaFile('rf_geomod/surface.lua')
AddCSLuaFile('rf_geomod/scorch.lua')
include('shared.lua')

util.AddNetworkString('rf_geomod_state')
util.AddNetworkString('rf_geomod_request')

local G=RFGeoMod
local emplacementImpact
hook.Add('OnEntityCreated','rf_geomod_emplacement_impact',function(ent)
    if ent:GetClass()=='env_explosion' and emplacementImpact then
        ent.RFGeoModImpact=emplacementImpact
    elseif ent:GetClass()=='entity_tank_rocket' then
        timer.Simple(0,function()
            if not IsValid(ent) or not ent.PhysicsCollide then return end
            local collide=ent.PhysicsCollide
            ent.PhysicsCollide=function(rocket,data,physics)
                local wall=G.WallFor(data.HitEntity)
                if not IsValid(wall) or not wall.BoxSource then return collide(rocket,data,physics) end
                -- Editable Emplacement creates a separate env_explosion in its
                -- collision callback. Carry the contact into the damage event.
                local previous=emplacementImpact
                emplacementImpact={wall=wall,point=data.HitPos,direction=rocket:GetForward()}
                local ok,err=xpcall(collide,debug.traceback,rocket,data,physics)
                emplacementImpact=previous
                if not ok then ErrorNoHalt(tostring(err)..'\n') end
            end
        end)
    end
end)

local maxChunks=CreateConVar('rf_geomod_max_chunks','48',FCVAR_ARCHIVE,
    'Maximum live detached GeoMod chunks; further detached parts become temporary rocks.',0,256)
-- Broken parts smaller than this (cubic units) shatter into temporary rocks.
local MIN_CHUNK_VOLUME=1000
local MAX_CHUNKS_PER_SPLIT=8
G.Chunks=G.Chunks or {}

local function liveChunks()
    for i=#G.Chunks,1,-1 do if not IsValid(G.Chunks[i]) then table.remove(G.Chunks,i) end end
    return #G.Chunks
end

local function copyOps(ops)
    local output={} for i,op in ipairs(ops or {}) do output[i]=op end
    return output
end

local function countCuts(ops)
    local count=0
    for _,op in ipairs(ops) do if (op.kind or G.OP_CUT)==G.OP_CUT then count=count+1 end end
    return count
end

local function snap(value,step) return math.Round(value*step)/step end
local function snapVector(v,step) return Vector(snap(v.x,step),snap(v.y,step),snap(v.z,step)) end

function ENT:Initialize()
    RFMapProtection.Apply(self,self.WallKeyValues or {})
    self:ApplyWallConfiguration(self.WallKeyValues or {})
    self.DynamicWall=true
    local loaded,err=self:LoadWallSource(self.BrushSourceModel)
    if not loaded then ErrorNoHalt('[GeoMod] '..tostring(err)..'\n') return end
    self:SetModel('models/hunter/blocks/cube025x025x025.mdl')
    self:DrawShadow(false)
    if not self.DynamicWall then self:SetMoveType(MOVETYPE_NONE) end
    self:SetHealth(1000000)
    self:SetSaveValue('m_takedamage',2)
    self:SetNWBool('rf_geomod_dynamic',self.DynamicWall)
    -- Map walls and chunks of map brushes depend on this map's BSP.
    if not self.BoxSource then self.DoNotDuplicate=true end
    if self.InitialOps or self.SeedPieces then
        local restored,reason=self:RestoreHistory(self.InitialOps or {},self.ProvidedPieces)
        -- Detached chunks are tentative. Their caller keeps the static geometry
        -- or emits debris if the engine cannot build a movable collider.
        if not restored and not self.IsChunk then ErrorNoHalt('[GeoMod] Could not restore wall history: '..reason..'\n') end
    else self:ResetWall() end
    self.ProvidedPieces=nil

end

-- Spawn from a recorded history (detached chunks, duplicator pastes).
function ENT:RestoreHistory(ops,pieces)
    pieces=pieces or G.Replay(ops,nil,nil,self.InitialPieces)
    if not pieces or #pieces==0 then return false,'no surviving convex pieces' end
    local built,failure=self:BuildPhysics(pieces)
    if not built then return false,failure=='collision_limit' and 'movable collision is too complex' or 'movable collision was rejected' end
    self.Pieces,self.Cuts,self.CutCount=pieces,ops,countCuts(ops)
    self.LastCutResult=nil self.LastDamageResult='restored'
    self.Revision=(self.Revision or 0)+1
    self:SetNWInt('rf_geomod_revision',self.Revision)
    self:SetNWString('rf_geomod_status','')
    self:SendState()
    return true
end

function ENT:ResetWall()
    -- Detached chunks have no intact form of their own.
    if self.IsChunk then self:Remove() return end
    local pieces = self.InitialPieces
    if not pieces then ErrorNoHalt('[GeoMod] Missing compiled brush source\n') return end
    self.PendingCuts=0
    self.CutRequests={} self.CutJobQueued=false
    self.PendingSplit=nil
    if self:IsPlayerHolding() then
        self.ResetOnDrop=true self:NextThink(CurTime())
        return
    end
    self.ResetOnDrop=nil
    if not self:BuildPhysics(pieces) then ErrorNoHalt('[GeoMod] Initial physics failed\n') return end
    self.Pieces,self.Cuts,self.CutCount = pieces,{},0
    self.LastCutResult=nil self.LastDamageResult='wall_reset'
    self.Revision = (self.Revision or 0)+1
    self:SetNWInt('rf_geomod_revision',self.Revision)
    self:SetNWString('rf_geomod_status','')
    self:SendState()
    hook.Run('RFGeoModGeometryChanged',self)
end

function ENT:SendState(ply)
    self:SetNWString('rf_geomod_effect_profile',G.WallEffectProfile(self))
    net.Start('rf_geomod_state') net.WriteEntity(self) net.WriteUInt(self.Revision or 0,16)
    net.WriteString(self.BrushSourceModel or '')
    net.WriteBool(self.DynamicWall==true) net.WriteBool(self.BoxSource==true)
    local seed=(self.Revision==1 or IsValid(ply)) and self.EncodedSeed
    net.WriteUInt(seed and #seed or 0,16)
    if seed then net.WriteData(seed,#seed) end
    net.WriteVector(self.BoxLow) net.WriteVector(self.BoxHigh)
    net.WriteString(self.SurfaceMaterialName) net.WriteString(self.CutMaterialName)
    net.WriteFloat(self.SurfaceRepeat) net.WriteFloat(self.CutRepeat)
    local ops=self.Cuts or {}
    net.WriteUInt(#ops,10)
    for _, op in ipairs(ops) do
        local kind=op.kind or G.OP_CUT
        net.WriteUInt(kind,2) net.WriteVector(op.center)
        if kind==G.OP_CUT then
            local n=op.normal or Vector()
            net.WriteFloat(op.radius) net.WriteUInt(op.seed or 0,16)
            -- Full precision: WriteVector rounds to 1/32, which would give
            -- clients a slightly different cutter than the server's.
            net.WriteFloat(n.x) net.WriteFloat(n.y) net.WriteFloat(n.z)
            net.WriteBool(op.bore==true)
            net.WriteBool(op.ram~=nil)
            if op.ram then
                local right,half,travel=op.ram.right,op.ram.half,op.ram.travel
                net.WriteFloat(right.x) net.WriteFloat(right.y) net.WriteFloat(right.z)
                net.WriteFloat(half.x) net.WriteFloat(half.y) net.WriteFloat(half.z)
                net.WriteFloat(travel.x) net.WriteFloat(travel.y) net.WriteFloat(travel.z)
            end
        end
    end
    if IsValid(ply) then net.Send(ply) else
        net.Broadcast()
        self.StateDirty=false self.NextStateSend=nil
        self.StateBroadcasts=(self.StateBroadcasts or 0)+1
    end
end

function ENT:QueueState()
    -- Coalesce network snapshots, not explosions. Authoritative carving and
    -- collision still process every hit; clients receive the newest full state.
    self.StateDirty=true
    self.NextStateSend=self.NextStateSend or CurTime()+.05
    self:NextThink(CurTime())
end

function ENT:Think()
    if self.GeoModImpactEjected then
        local physics=self:GetPhysicsObject()
        if IsValid(physics) and (physics:IsAsleep() or not physics:IsMotionEnabled()) then
            self.GeoModImpactEjected=nil
        end
    end
    if self.ResetOnDrop and not self:IsPlayerHolding() then self:ResetWall() end
    if self.CutRequests then self:ScheduleCuts() end
    if self.StateDirty and CurTime()>=self.NextStateSend then self:SendState() end
    local waiting=(self.PendingCuts or 0)>0 or self.PendingSplit or self.ResetOnDrop
    self:NextThink(self.NextStateSend or CurTime()+(waiting and .05 or 1))
    return true
end

local MAX_CUT_BATCH=4
local CUT_MESSAGES={
    cut_history_limit='Cut history limit reached; use rf_geomod_reset.',
    collision_limit='Wall collision complexity limit reached. The last accepted shape is intact.',
    physics_rebuild_failed='Physics rebuild rejected this cut.',
}

function ENT:ScheduleCuts()
    if self.CutJobQueued or self:IsPlayerHolding() or self.ResetOnDrop then return end
    if not self.CutRequests[1] and not self.PendingSplit then return end
    self.CutJobQueued=true
    G.ScheduleCut(self,function(job,checkpoint)
        if self:IsPlayerHolding() then return end
        if self.PendingSplit then
            self.PendingSplit=nil
            self:ProcessSplit(job,checkpoint)
        end
        if IsValid(self) and not self.PendingSplit then self:ApplyCuts(job,checkpoint) end
    end,function()
        if not IsValid(self) then return end
        self.CutJobQueued=false
        self:ScheduleCuts()
    end,function()
        if not IsValid(self) then return end
        self.CutJobQueued=false
        self.PendingCuts=#self.CutRequests
        self:ScheduleCuts()
    end)
end

function ENT:QueueCarve(position,normal,radius,effectOrigin,onComplete,travel,contact,fracture)
    if not self.Pieces then return false end
    if (self.CutCount or 0)>=G.MaxCuts or #self.Cuts>=G.MaxOps-1 then
        self.LastCutResult='cut_history_limit'
        self:SetNWString('rf_geomod_status',CUT_MESSAGES.cut_history_limit)
        return false
    end
    if (self.CutCount or 0)+(self.PendingCuts or 0)>=G.MaxCuts then return false end
    self.CutRequests=self.CutRequests or {}
    self.CutRequests[#self.CutRequests+1]={position=position,normal=normal,radius=radius,
        effectOrigin=effectOrigin,seed=contact and contact.seed or math.random(1,65535),
        done=onComplete,travel=travel,contact=contact,fracture=fracture}
    self.PendingCuts=(self.PendingCuts or 0)+1
    self:NextThink(CurTime())
    self:ScheduleCuts()
    return true
end

function ENT:CarveAt(position,normal,radius,effectOrigin,onComplete)
    return self:QueueCarve(self:WorldToLocal(position),self:WorldToLocal(self:GetPos()+normal),radius,
        self:WorldToLocal(effectOrigin or position),onComplete)
end

function ENT:CutContact(point,normal,radius,fracture)
    local position=self:WorldToLocal(point)
    local direction=self:WorldToLocal(self:GetPos()+normal)
    local sourceDirection=fracture and self:WorldToLocal(self:GetPos()+fracture)
    local op=fracture and G.ContactFracture(position,radius) or G.ContactCut(position,radius)
    return self:QueueCarve(position,direction,radius,nil,nil,nil,op,sourceDirection)
end

function ENT:PhysicsCollide(data)
    G.HandlePhysicsImpact(self,data)
end

function ENT:PlanCut(pieces,request,checkpoint)
    local position,normal=request.position,request.normal
    local op=request.contact
    if not op then
        local radius=math.Clamp(request.radius,24,100)*G.HardnessCraterScale(self.Hardness)
        radius=math.Round(math.Clamp(radius,6,150)*8)/8
        if request.travel then
            -- A previous hit may have removed the rocket's contact face.
            -- Continue along its flight path through the staged geometry.
            local direction=request.travel
            local reach=(self.High-self.Low):Length()+8
            local hit=G.Trace(pieces,position-direction*4,direction*reach)
            if not hit then return nil,'no_remaining_surface' end
            position,normal=hit.HitPos,-direction
            if self.BoxSource and math.abs(direction.x)>.9 then
                normal=Vector(direction.x<0 and 1 or -1,0,0)
            end
        elseif not normal then
            position,normal=G.ClosestSurface(pieces,position,checkpoint)
            if not position then return nil,'no_remaining_surface' end
        end
        op={kind=G.OP_CUT,center=snapVector(position+normal*radius*.4,8),
            radius=radius,seed=request.seed,normal=snapVector(normal,4096),bore=false}
    end
    local extracted=request.fracture and {}
    local remaining,err=G.SubtractCut(pieces,op,checkpoint,extracted)
    if not remaining then return nil,'complexity_limit',err end
    local remainingVolume=G.Volume(remaining)
    local removed=G.Volume(pieces)-remainingVolume
    if removed<.1 then return nil,'no_volume_removed' end
    if self:IsDynamicWall() and remainingVolume<MIN_CHUNK_VOLUME then
        -- No collider or solid fragments for a remnant below the chunk limit.
        remaining,extracted={},nil
        removed=removed+remainingVolume
    end
    local hulls,failure=self:PrepareCollision(remaining,checkpoint)
    if not hulls then return nil,failure=='collision_limit' and failure or 'physics_rebuild_failed' end
    local sourceDirection=request.fracture or (request.travel and -request.travel)
        or ((request.effectOrigin or request.position)-position)
    return {pieces=remaining,hulls=hulls,op=op,origin=request.effectOrigin or position,normal=normal,
        direction=G.DebrisDirection(sourceDirection,normal),removed=removed,extracted=extracted}
end

function ENT:ApplyCuts(job,checkpoint)
    local began=job:Time()
    local pieces=self.Pieces
    local processed,accepted={},{}
    local hulls
    for _=1,MAX_CUT_BATCH do
        local request=table.remove(self.CutRequests,1)
        if not request then break end
        processed[#processed+1]=request
        request.message=nil
        local cut
        if self.CutCount+#accepted>=G.MaxCuts or #self.Cuts+#accepted>=G.MaxOps-1 then
            request.result='cut_history_limit'
        else
            cut,request.result,request.message=self:PlanCut(pieces,request,checkpoint)
        end
        if cut then
            pieces,hulls=cut.pieces,cut.hulls
            accepted[#accepted+1]=cut
            request.result='accepted'
        end
        checkpoint()
    end
    if #accepted>0 then
        local built,failure=self:BuildPhysics(pieces,checkpoint,hulls)
        if failure=='held' then
            for i=#processed,1,-1 do table.insert(self.CutRequests,1,processed[i]) end
            return
        elseif built then
            self.Pieces=pieces
            for _,cut in ipairs(accepted) do self.Cuts[#self.Cuts+1]=cut.op end
            self.CutCount=self.CutCount+#accepted
            self.Revision=self.Revision+#accepted
            self:SetNWInt('rf_geomod_revision',self.Revision)
            self:SetNWString('rf_geomod_status','')
            self.LastBuildMs=(job:Time()-began)*1000
            local fallback=self:GetNWEntity('rf_geomod_fallback')
            self:SetNWEntity('rf_geomod_fallback',NULL)
            if IsValid(fallback) then fallback:Remove() end
            self:QueueState()
            hook.Run('RFGeoModGeometryChanged',self)
            for _,cut in ipairs(accepted) do
                if cut.extracted then
                    G.SpawnImpactChunks(self,cut.extracted,cut.origin,cut.normal,cut.op.radius,checkpoint)
                end
                if G.EmitDestruction then
                    local origin=self:LocalToWorld(cut.origin)
                    local normal=(self:LocalToWorld(cut.normal)-self:GetPos()):GetNormalized()
                    local direction=(self:LocalToWorld(cut.direction)-self:GetPos()):GetNormalized()
                    G.EmitDestruction(self,origin,normal,cut.op.radius,cut.removed,checkpoint,direction)
                end
            end
            self:ProcessSplit(job,checkpoint)
        else
            self:BuildPhysics(self.Pieces)
            for _,request in ipairs(processed) do
                if request.result=='accepted' then request.result='physics_rebuild_failed' end
            end
        end
    end
    for _,request in ipairs(processed) do
        if IsValid(self) then
            self.PendingCuts=self.PendingCuts-1
            self.LastCutResult=request.result
            local message=request.message or CUT_MESSAGES[request.result]
            if message or request.result=='accepted' then self:SetNWString('rf_geomod_status',message or '') end
        end
        if request.done then request.done(request.result=='accepted') end
    end
end

function ENT:CachedIslands(checkpoint)
    local cache=self.IslandCache
    if not cache or cache.pieces~=self.Pieces then
        self.IslandContacts=self.IslandContacts or setmetatable({},{__mode='k'})
        cache={pieces=self.Pieces,islands=G.Islands(self.Pieces or {},self.IslandContacts,checkpoint)}
        self.IslandCache=cache
    end
    return cache.islands
end

function ENT:ShatterIsland(island)
    if not G.SpawnFragment then return end
    local size=math.Clamp(island.volume^(1/3)*0.5,2,10)
    local count=math.Clamp(math.ceil(island.volume/(size^3*8)),1,3)
    local world=self:LocalToWorld(island.centroid)
    for _=1,count do
        G.SpawnFragment(world+VectorRand()*size,VectorRand()*60+Vector(0,0,40),size,self.CutMaterialName,nil,
            G.WallEffectProfile(self))
    end
end

-- A chunk joins every undo entry that holds the wall it broke from, so undoing
-- a placed (or pasted) wall also removes all of its pieces. Chunks of chunks
-- follow through the same entry.
local function shareUndo(parent,child)
    if not undo or not undo.GetTable then return end
    for _,entries in pairs(undo.GetTable() or {}) do
        for _,entry in pairs(entries) do
            if istable(entry) and istable(entry.Entities) then
                for _,ent in pairs(entry.Entities) do
                    if ent==parent then table.insert(entry.Entities,child) break end
                end
            end
        end
    end
end

function ENT:SpawnChunk(baseOps,island,pieces,checkpoint)
    local center=island.opCenter
    local localPieces=G.Translate(pieces,center,checkpoint)
    if #localPieces~=#pieces then return false end
    local child=ents.Create('rf_geomod_dynamic')
    if not IsValid(child) then return false end
    local config=table.Copy(self.WallKeyValues or {})
    config.disable_physgun='0'
    child.WallKeyValues=config
    child.BrushSourceModel=self.BrushSourceModel
    child.BoxSource=self.BoxSource
    child.DynamicWall,child.FrozenWall,child.IsChunk=true,false,true
    local ops=copyOps(baseOps)
    ops[#ops+1]={kind=G.OP_KEEP,center=center}
    if self.SeedPieces then
        child.SeedPieces,child.SeedMaterials=localPieces,self.WallMaterialNames
        child.EncodedSeed=G.PackMovableSeed(localPieces,self.WallMaterialNames)
        if not child.EncodedSeed then child:Remove() return false end
    else
        child.InitialOps=ops
        child.ProvidedPieces=localPieces
    end
    child.GeoModSourceWall=self
    child.RFGeoModOwner=self.RFGeoModOwner
    child:SetPos(self:LocalToWorld(center)) child:SetAngles(self:GetAngles())
    child:Spawn()
    if not child.Pieces then child:Remove() return false end
    child:Activate()
    local parentPhysics,physics=self:GetPhysicsObject(),child:GetPhysicsObject()
    if self:IsDynamicWall() and IsValid(parentPhysics) and IsValid(physics) and parentPhysics:IsMotionEnabled() then
        physics:SetVelocity(parentPhysics:GetVelocityAtPoint(child:GetPos()))
        physics:AddAngleVelocity(parentPhysics:GetAngleVelocity())
    end
    local owner=self.RFGeoModOwner
    if IsValid(owner) then
        owner:AddCleanup('rf_geomod_walls',child)
        if child.CPPISetOwner then child:CPPISetOwner(owner) end
    end
    shareUndo(self,child)
    G.Chunks[#G.Chunks+1]=child
    return true
end

function G.SpawnDetachedWall(wall,island,pieces)
    if liveChunks()>=maxChunks:GetInt() then return end
    local center=island.centroid
    local localPieces=G.Translate(pieces,center)
    -- A numerical sliver can collapse in the child's local frame. Only
    -- remove an authored island when the child can carry all of its pieces.
    if #localPieces~=#pieces then return end
    local encoded=G.PackMovableSeed(localPieces,wall.WallMaterialNames)
    if not encoded then return end
    local child=ents.Create('rf_geomod_dynamic')
    if not IsValid(child) then return end
    child.SeedPieces,child.SeedMaterials,child.EncodedSeed=localPieces,wall.WallMaterialNames,encoded
    local dynamic=wall:GetClass()=='rf_geomod_dynamic'
    child.WallKeyValues={hardness=wall.Hardness,cut_material=wall.CutMaterialName,cut_repeat=wall.CutRepeat,
        surface_material=wall.SurfaceMaterialName,surface_repeat=wall.SurfaceRepeat,disable_physgun='0',
        effects_profile=G.WallEffectProfile(wall)}
    child.IsChunk,child.FrozenWall=true,true
    child.GeoModSourceWall=wall
    if dynamic then
        child.RFGeoModOwner=wall.RFGeoModOwner
        child:SetPos(wall:LocalToWorld(center))
        child:SetAngles(wall:GetAngles())
    else
        child:SetPos(center)
    end
    child:Spawn()
    if not child.Pieces or not IsValid(child:GetPhysicsObject()) then child:Remove() return end
    child:Activate()
    if dynamic then
        local owner=child.RFGeoModOwner
        if IsValid(owner) then
            owner:AddCleanup('rf_geomod_walls',child)
            if child.CPPISetOwner then child:CPPISetOwner(owner) end
        end
        shareUndo(wall,child)
    end
    G.Chunks[#G.Chunks+1]=child
    return child
end

function G.SpawnImpactChunks(wall,extracted,point,normal,radius,checkpoint)
    if liveChunks()>=maxChunks:GetInt() then return end
    local parts={}
    for _,pieces in ipairs(G.FracturePieces(extracted,normal,checkpoint)) do
        for _,island in ipairs(G.Islands(pieces,nil,checkpoint)) do
            if island.volume>=MIN_CHUNK_VOLUME then
                local members={}
                for _,index in ipairs(island.indices) do members[#members+1]=pieces[index] end
                parts[#parts+1]={island=island,pieces=members}
            end
        end
    end
    table.sort(parts,function(a,b) return a.island.volume>b.island.volume end)
    local dynamic=wall:GetClass()=='rf_geomod_dynamic'
    local parentPhysics=dynamic and wall:GetPhysicsObject()
    local worldPoint=dynamic and wall:LocalToWorld(point) or point
    local outward=dynamic and (wall:LocalToWorld(normal)-wall:GetPos()):GetNormalized() or normal
    wall.GeoModNextImpact=math.max(wall.GeoModNextImpact or 0,CurTime()+.14)
    for index=1,math.min(#parts,3) do
        local part=parts[index]
        local child=G.SpawnDetachedWall(wall,part.island,part.pieces)
        if IsValid(child) then
            local physics=child:GetPhysicsObject()
            local offset=child:GetPos()-worldPoint
            local spread=(offset-outward*offset:Dot(outward))*(60/radius)
            local inherited=IsValid(parentPhysics) and parentPhysics:GetVelocityAtPoint(child:GetPos()) or Vector()
            -- The launch is part of the original impact. Let overlapping
            -- fragments collide and settle without generating more cuts.
            child.GeoModImpactEjected=true
            physics:EnableMotion(true)
            physics:SetVelocity(inherited+outward*55+spread)
            physics:Wake()
        end
    end
end

function ENT:ProcessSplit(job,checkpoint)
    if self:IsPlayerHolding() then self.PendingSplit=true return end
    local pieces=self.Pieces or {}
    local dynamic=self:IsDynamicWall()
    if #pieces==0 then
        if dynamic then self:Remove() end
        return
    end
    local started=job:Time()
    local islands=self:CachedIslands(checkpoint)
    self.LastIslandMs=(job:Time()-started)*1000
    self.LastIslandCount=#islands
    local largest=islands[1]
    for _,island in ipairs(islands) do if island.volume>largest.volume then largest=island end end
    if dynamic and largest.volume<MIN_CHUNK_VOLUME then
        for _,island in ipairs(islands) do self:ShatterIsland(island) checkpoint() end
        self:Remove()
        return
    end
    if dynamic and #islands<2 then return end
    local stay={}
    stay[largest]=true
    local detached={}
    for _,island in ipairs(islands) do if not stay[island] then detached[#detached+1]=island end end
    table.sort(detached,function(a,b) return a.volume>b.volume end)
    -- Each detached island needs a DROP record; leave any excess in place.
    local capacity=G.MaxOps-#self.Cuts
    while #detached>capacity do table.remove(detached) end
    if #detached==0 then return end
    local baseOps=copyOps(self.Cuts)
    local removed={}
    for _,island in ipairs(detached) do
        -- 1/8-unit centers survive WriteVector exactly, so clients select the
        -- same island and use the same chunk origin as the server.
        island.opCenter=snapVector(island.centroid,8)
        for _,index in ipairs(island.indices) do removed[index]=true end
    end
    local remaining={}
    for index,piece in ipairs(pieces) do if not removed[index] then remaining[#remaining+1]=piece end end
    local built,failure=self:BuildPhysics(remaining,checkpoint)
    if not built then
        if failure=='held' then self.PendingSplit=true end
        if not failure then self:BuildPhysics(pieces) end
        return
    end
    self.Pieces=remaining
    for _,island in ipairs(detached) do
        self.Cuts[#self.Cuts+1]={kind=G.OP_DROP,center=island.opCenter}
    end
    self.Revision=self.Revision+1
    self:SetNWInt('rf_geomod_revision',self.Revision)
    self:QueueState()
    hook.Run('RFGeoModGeometryChanged',self)
    local spawned=0
    for _,island in ipairs(detached) do
        local members={}
        for _,index in ipairs(island.indices) do members[#members+1]=pieces[index] end
        if island.volume>=MIN_CHUNK_VOLUME and spawned<MAX_CHUNKS_PER_SPLIT and liveChunks()<maxChunks:GetInt()
            and self:SpawnChunk(baseOps,island,members,checkpoint) then
            spawned=spawned+1
        else
            self:ShatterIsland(island)
        end
        checkpoint()
    end
    self.LastSplit={islands=#islands,detached=#detached,chunks=spawned,ms=(job:Time()-started)*1000}
end

function ENT:OnTakeDamage(info)
    self.DamageEvents=(self.DamageEvents or 0)+1
    self.LastDamageType=info:GetDamageType()
    if self:IsDynamicWall() then self:TakePhysicsDamage(info) end
    if not (info:IsExplosionDamage() or info:IsDamageType(DMG_BLAST_SURFACE)) then
        self.LastDamageResult='not_explosion_damage' return
    end
    local inflictor = info:GetInflictor()
    -- Retail robot missiles keep their crater size independently of scaled AI
    -- health damage (Tank Bot deals 6.25 on Normal, below the ordinary gate).
    local crater = IsValid(inflictor) and inflictor.RFGeoModCraterRadius or 0
    if info:GetDamage()<10 and crater<=0 then self.LastDamageResult='below_damage_threshold' return end
    local position = info:GetDamagePosition()
    if position:LengthSqr() == 0 and IsValid(inflictor) then position=inflictor:GetPos() end
    local radius = crater>0 and crater or G.BlastRadius(info:GetDamage())
    local onCut=IsValid(inflictor) and inflictor.RFOnGeoModCut
    local impact=IsValid(inflictor) and inflictor.RFGeoModImpact
    local travel
    if impact and impact.wall==self then
        position=impact.point
        travel=self:WorldToLocal(self:GetPos()+impact.direction):GetNormalized()
        if inflictor:GetClass()=='env_explosion' then
            local magnitude=tonumber(inflictor:GetInternalVariable('m_iMagnitude'))
            if magnitude and magnitude>0 then radius=G.BlastRadius(magnitude) end
        end
    end
    if self:QueueCarve(self:WorldToLocal(position),nil,radius,nil,function(accepted)
        if IsValid(self) then
            if accepted then self.BlastDamageEvents=(self.BlastDamageEvents or 0)+1 end
            self.LastDamageResult=self.LastCutResult or 'rejected'
        end
        if accepted and onCut then onCut() end
    end,travel) then
        self.LastDamageResult='queued'
        if IsValid(inflictor) then inflictor.RFGeoModCutQueued=true end
    end
end

-- Toolgun walls (RF-071) -----------------------------------------------------

local function validMaterial(path)
    path=string.lower(string.Trim(tostring(path or ''))):gsub('\\','/'):gsub('^materials/',''):gsub('%.vmt$','')
    if path=='' or #path>160 or path:find('..',1,true) or not path:match('^[%w_%-/%.]+$') then return end
    if not file.Exists('materials/'..path..'.vmt','GAME') then return end
    return path
end

G.WallLimits={thickness={2,256},width={8,1024},height={8,1024},repeat_size={8,1024}}

-- Clamp an untrusted toolgun or duplicator configuration.
function G.SanitizeWallConfig(input)
    input=istable(input) and input or {}
    local limits=G.WallLimits
    local function size(value,range,default) return math.Round(math.Clamp(tonumber(value) or default,range[1],range[2])) end
    local thickness=size(input.thickness,limits.thickness,16)
    local width=size(input.width,limits.width,128)
    local height=size(input.height,limits.height,128)
    return {
        thickness=thickness,width=width,height=height,
        mins=Vector(-thickness/2,-width/2,0),maxs=Vector(thickness/2,width/2,height),
        surface_material=validMaterial(input.surface_material) or G.DefaultSurfaceMaterial,
        cut_material=validMaterial(input.cut_material) or G.DefaultCutMaterial,
        effects_profile=G.EffectProfileID(input.effects_profile),
        surface_repeat=size(input.surface_repeat,limits.repeat_size,128),
        cut_repeat=size(input.cut_repeat,limits.repeat_size,128),
        hardness=G.ClampHardness(input.hardness),
        disable_physgun='0',
    }
end

local function sanitizeOps(input)
    if not istable(input) then return end
    local ops,cuts={},0
    for _,op in ipairs(input) do
        if #ops>=G.MaxOps or not istable(op) or not isvector(op.center) then return end
        local kind=tonumber(op.kind) or G.OP_CUT
        if kind==G.OP_CUT then
            cuts=cuts+1
            if cuts>G.MaxCuts or not isvector(op.normal) then return end
            local clean={kind=kind,center=snapVector(op.center,8),radius=math.Clamp(tonumber(op.radius) or 24,6,150),
                seed=math.Clamp(math.floor(tonumber(op.seed) or 1),0,65535),normal=snapVector(op.normal,4096),
                bore=op.bore==true}
            local ram=op.ram
            if ram~=nil and (not istable(ram) or not G.SetRamShape(clean,op.normal,ram.right,ram.half,ram.travel)) then return end
            ops[#ops+1]=clean
        elseif kind==G.OP_KEEP or kind==G.OP_DROP then
            ops[#ops+1]={kind=kind,center=snapVector(op.center,8)}
        else return end
    end
    return ops
end

function G.SpawnWall(ply,pos,ang,config,ops,frozen)
    local wall=ents.Create('rf_geomod_dynamic')
    if not IsValid(wall) then return end
    wall.WallKeyValues=G.SanitizeWallConfig(config)
    wall.BoxSource,wall.DynamicWall,wall.FrozenWall=true,true,frozen==true
    wall.InitialOps=sanitizeOps(ops)
    wall.IsChunk=wall.InitialOps~=nil and #wall.InitialOps>0 and wall.InitialOps[#wall.InitialOps].kind==G.OP_KEEP or nil
    wall.RFGeoModOwner=ply
    wall:SetPos(pos) wall:SetAngles(ang)
    wall:Spawn() wall:Activate()
    if not wall.Pieces then wall:Remove() return end
    if IsValid(ply) and wall.CPPISetOwner then wall:CPPISetOwner(ply) end
    return wall
end

-- Duplicator and saves: store the configuration and history, never the
-- generated geometry, meshes or physics tables.
function ENT:OnEntityCopyTableFinish(data)
    for key in pairs(self:GetTable()) do data[key]=nil end
    local physics=self:GetPhysicsObject()
    data.RFGeoModWall={config=table.Copy(self.WallKeyValues or {}),ops=copyOps(self.Cuts),
        frozen=IsValid(physics) and not physics:IsMotionEnabled()}
end

duplicator.RegisterEntityClass('rf_geomod_dynamic',function(ply,data)
    local saved=data.RFGeoModWall
    if not istable(saved) then return end
    if IsValid(ply) and not ply:CheckLimit('rf_geomod_walls') then return end
    local wall=G.SpawnWall(ply,data.Pos,data.Angle,saved.config,saved.ops,saved.frozen==true)
    if IsValid(wall) and IsValid(ply) then
        ply:AddCount('rf_geomod_walls',wall) ply:AddCleanup('rf_geomod_walls',wall)
    end
    return wall
end,'Data')

net.Receive('rf_geomod_request',function(_,ply)
    local ent=net.ReadEntity()
    if not IsValid(ent) or ent:GetClass()~='rf_geomod_dynamic' then return end
    -- Allow a joining client to request several different walls together while
    -- still limiting repeated requests for the same entity.
    ply.RFGeoModRequests=ply.RFGeoModRequests or setmetatable({},{__mode='k'})
    if (ply.RFGeoModRequests[ent] or 0)>CurTime() then return end
    ply.RFGeoModRequests[ent]=CurTime()+0.5
    ent:SendState(ply)
end)

concommand.Add('rf_geomod_status',function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    if G.Static then G.Static.Status(ply) end
    local walls
    if IsValid(ply) then
        local ent=ply:GetEyeTrace().Entity
        if IsValid(ent) and IsValid(ent.GeoModProxy) then ent=ent.GeoModProxy end
        if IsValid(ent) and ent:GetClass()=='rf_geomod_dynamic' then walls={ent} end
    end
    walls=walls or ents.FindByClass('rf_geomod_dynamic')
    for _,wall in ipairs(walls) do
        if wall.Pieces then
            local split=wall.LastSplit
            local message=string.format('[GeoMod %s%s] cuts=%d/%d ops=%d pieces=%d/%d hardness=%d damage_events=%d accepted=%d last_type=%s result=%s split=%s status=%s\n',
                wall.BrushSourceModel or 'box',wall.DynamicWall and ' dynamic' or '',wall.CutCount or 0,G.MaxCuts,#wall.Cuts,
                #wall.Pieces,G.MaxPieces,wall.Hardness or 50,
                wall.DamageEvents or 0,wall.BlastDamageEvents or 0,tostring(wall.LastDamageType or 'none'),
                wall.LastDamageResult or 'none',
                split and string.format('%d islands/%d detached/%d chunks/%.1fms',split.islands,split.detached,split.chunks,split.ms) or 'none',
                wall:GetNWString('rf_geomod_status',''))
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE,message) else Msg(message) end
        end
    end
end)

-- Retire the old mesh-only hook when this file is hot-reloaded.
hook.Remove('PhysgunPickup','rf_geomod_fixed_wall')
