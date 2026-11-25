-- Static replacement: immutable authored sources, sparse world-space chunks,
-- bounded work queues, one world cutter per impact, and late-join replay.
local G,V,C=RFGeoMod,RFGeoMod.Field,RFGeoMod.FieldCache
local R={groups={},queue={},generation=0,serial=0,states={},pending={}}
G.Static=R
local MSG='rf_geomod_field_state'
-- Live cuts get a larger per-frame slice than initial preparation: their
-- latency is visible, and each job is short. Preparation keeps 2/4 ms.
R.LiveBudget=CreateConVar(SERVER and 'rf_geomod_sv_cut_budget_ms' or 'rf_geomod_cl_cut_budget_ms',SERVER and '6' or '8',
    FCVAR_ARCHIVE,'Per-frame GeoMod work budget, in milliseconds, while applying a live cut.',1,50)
local function push(owner,fn,done,front,live,failed)
    local request={owner=owner,fn=fn,done=done,generation=R.generation,live=live,failed=failed}
    if front then table.insert(R.queue,1,request) else R.queue[#R.queue+1]=request end
end
function G.ScheduleCut(owner,fn,done,failed)
    local scheduledAt=SysTime()
    push(owner,function(job,checkpoint)
        job.scheduledAt=scheduledAt
        return fn(job,checkpoint)
    end,done,false,true,failed)
end
local function guarded(fn)
    return function(...)
        local ok,err=xpcall(fn,debug.traceback,...)
        if not ok then R.error=err ErrorNoHalt('[GeoMod field] '..tostring(err)..'\n') end
    end
end
local function step(budget)
    local began=SysTime()
    local live=R.LiveBudget:GetFloat()/1000
    while true do
        if not R.active then
            local following=R.queue[1]
            if not following or SysTime()>=began+(following.live and math.max(budget,live) or budget) then return end
            local request=table.remove(R.queue,1)
            if request.generation==R.generation and (not request.owner or IsValid(request.owner)) then
                request.job=V.NewJob(request.fn) R.active=request
            end
        end
        local request=R.active
        local deadline=began+(request and request.live and math.max(budget,live) or budget)
        if request and SysTime()>=deadline then return end
        if request then
            if request.generation~=R.generation or (request.owner and not IsValid(request.owner)) then R.active=nil
            else
                local ok,finished=pcall(V.Step,request.job,math.max(0,deadline-SysTime()))
                if not ok then
                    R.active=nil
                    if request.failed then request.failed() end
                    error(finished)
                end
                if finished then
                    R.active=nil
                    if request.done then request.done(request.job) end
                else return end
            end
        end
    end
end
local function preparePhysics(ent,triangles,checkpoint)
    local pool=ent.FieldPhysicsPool or {} ent.FieldPhysicsPool=pool
    return C.PreparePhysics(triangles,pool,checkpoint)
end
local function commitPhysics(ent,vertices,low,high)
    if #vertices==0 then ent:PhysicsDestroy() ent:SetSolid(SOLID_NONE) return end
    assert(ent:PhysicsFromMesh(vertices,'concrete'),'Static field collision construction failed')
    ent:SetSolid(SOLID_VPHYSICS) ent:SetMoveType(MOVETYPE_NONE) ent:EnableCustomCollisions()
    local physics=ent:GetPhysicsObject() assert(IsValid(physics),'Static field physics unavailable')
    physics:EnableMotion(false) physics:SetPos(vector_origin) physics:SetAngles(angle_zero)
    ent:SetCollisionBounds(low-Vector(1,1,1),high+Vector(1,1,1))
    if CLIENT then ent:SetRenderBounds(low-Vector(1,1,1),high+Vector(1,1,1)) end
end
local function buildChunk(wall,chunk,checkpoint,base,renderData,boundary)
    wall.FieldProgress={key=chunk.key,stage='boundary'}
    local volume=wall.FieldVolume
    local old=volume.chunks[chunk.key]
    local triangles
    if base then
        triangles=base.triangles volume.chunks[chunk.key]=base
        wall.FieldCache.restored_chunks=wall.FieldCache.restored_chunks+1
    else
        triangles=boundary[chunk.key] or {}
        volume.chunks[chunk.key]={triangles=triangles,revision=volume.revision}
        wall.FieldCache.contours=wall.FieldCache.contours+1
    end
    local ent=wall.FieldChunks[chunk.key]
    assert(IsValid(ent),'Static field chunk entity missing: '..chunk.key)
    local unchanged=ent.FieldBuilt and old and V.SameTriangles(old.triangles,triangles)
    if not unchanged then
        wall.FieldProgress.stage='physics buffer'
        local physics=base and base.physics or preparePhysics(ent,triangles,checkpoint)
        if base and base.physics then ent.FieldPhysicsPool=physics.vertices end
        if volume.revision==0 then volume.chunks[chunk.key].physics=physics end
        wall.FieldProgress.stage='render buffer'
        local bundle
        if CLIENT then
            bundle=renderData and G.FieldRender.Restore(wall,ent,renderData,checkpoint) or G.FieldRender.Prepare(wall,ent,triangles,checkpoint)
            if renderData then wall.FieldCache.restored_render=wall.FieldCache.restored_render+1 end
        end
        wall.FieldProgress.stage='physics upload'
        commitPhysics(ent,physics.vertices,physics.low,physics.high)
        if CLIENT then G.FieldRender.Commit(wall,ent,bundle) end
    end
    ent.FieldBuilt=true ent.FieldRevision=volume.revision
    wall.FieldProgress.stage='complete'
    return #triangles,not unchanged
end

-- Static collision supports island detection with convex solids only when
-- damage needs it. Render and VPhysics triangles still come from the boundary.
local function mirrorPieces(wall,history,last,checkpoint)
    local pieces=wall.DetachPieces or wall.InitialPieces
    local detached
    for i=(wall.DetachApplied or 0)+1,last do
        local op=history[i]
        if op.detach then
            local island=G.NearestIsland(G.Islands(pieces,nil,checkpoint),op.center)
            if not island then return end
            local member={}
            for _,index in ipairs(island.indices) do member[index]=true end
            local remaining={}
            detached={}
            for index,piece in ipairs(pieces) do
                local output=member[index] and detached or remaining
                output[#output+1]=piece
            end
            pieces=remaining
        else
            pieces=G.Subtract(pieces,op.center,op.radius,op.seed,op.normal,checkpoint)
            if not pieces then return end
        end
    end
    wall.DetachPieces,wall.DetachApplied=pieces,last
    return pieces,detached
end
function G.WallFor(ent)
    if not IsValid(ent) then return end
    local class=ent:GetClass()
    if class=='rf_geomod_field' or class=='rf_geomod_dynamic' then return ent end
    local wall=ent.GeoModProxy or ent:GetNWEntity('rf_geomod_field_group')
    if not IsValid(wall) then wall=ent:GetOwner() end
    if IsValid(wall) and (wall:GetClass()=='rf_geomod_field' or wall:GetClass()=='rf_geomod_dynamic') then return wall end
end
function G.IsWall(ent) return IsValid(G.WallFor(ent)) end
function G.RenderSurfaces(wall,exteriorOnly)
    local result={}
    if wall:GetClass()=='rf_geomod_field' then
        local state=wall.FieldClientState
        if state then
            if not state.initialReady then return state.baseTriangles or {} end
            for _,chunk in pairs(wall.FieldChunks or {}) do
                for id,vertices in pairs(chunk.FieldVertices or {}) do if not exteriorOnly or id~=2 then result[#result+1]=vertices end end
            end
        end
    else
        for _,groups in ipairs({wall.RenderTriangles or {},wall.DynamicTriangles or {}}) do
            for id,vertices in ipairs(groups) do if not exteriorOnly or id~=2 then result[#result+1]=vertices end end
        end
    end
    return result
end

if SERVER then
    util.AddNetworkString(MSG) util.AddNetworkString(MSG..'_request') util.AddNetworkString(MSG..'_ready')
    local function snapshot(wall)
        local data=table.Copy(wall.FieldData)
        data.entity=wall:EntIndex() data.serial=wall.FieldSerial data.revision=wall.Revision or 0
        data.history={} data.chunks={}
        for _,op in ipairs(wall.Cuts or {}) do
            data.history[#data.history+1]={center={op.center.x,op.center.y,op.center.z},detach=op.detach,
                normal=op.normal and {op.normal.x,op.normal.y,op.normal.z},radius=op.radius,seed=op.seed,
                scorch_origin=op.scorch_origin and {op.scorch_origin.x,op.scorch_origin.y,op.scorch_origin.z}}
        end
        for key,ent in pairs(wall.FieldChunks or {}) do if IsValid(ent) then data.chunks[key]=ent:EntIndex() end end
        for i,brush in ipairs(wall.SourceBrushes or {}) do
            local native=IsValid(brush) and brush.FieldNative
            data.sources[i].native=IsValid(native) and native:EntIndex() or 0
            local owners={}
            for group in pairs(IsValid(brush) and brush.FieldGroups or {}) do if IsValid(group) then
                owners[#owners+1]={group:EntIndex(),group.FieldSerial}
            end end
            data.sources[i].native_owners=owners
        end
        return data
    end
    function R.Send(wall,ply)
        if not IsValid(wall) or not wall.FieldData or not wall.FieldCatalogReady then return end
        local bytes=assert(util.Compress(util.TableToJSON(snapshot(wall))))
        assert(#bytes<60000,'Field snapshot exceeds the supported packet size')
        net.Start(MSG) net.WriteUInt(#bytes,16) net.WriteData(bytes,#bytes)
        if IsValid(ply) then net.Send(ply) else net.Broadcast() end
    end
    function R.Status(ply)
        for wall in pairs(R.groups) do if IsValid(wall) then
            local v=wall.FieldVolume
            local message=string.format('[GeoMod field %d] ready=%s cuts=%d chunks=%d spacing=%s\n',
                wall:EntIndex(),tostring(wall.FieldReady==true),#wall.Cuts,table.Count(wall.FieldChunks),tostring(v.spacing))
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE,message) else Msg(message) end
        end end
    end
    local function nativeFor(brush)
        if IsValid(brush.FieldNative) then return brush.FieldNative end
        local native=ents.Create('func_brush')
        native:SetPos(brush:GetPos()) native:SetAngles(brush:GetAngles()) native:SetKeyValue('Solidity','2')
        native:SetModel(brush:GetModel()) native:Spawn() native:SetSolid(SOLID_BSP) native:SetNotSolid(false)
        native:SetMoveType(MOVETYPE_NONE) RFMapProtection.Apply(native,brush.WallKeyValues or {})
        brush.FieldNative=native brush:DeleteOnRemove(native)
        return native
    end
    local function sourceReady(brush,ply)
        for group in pairs(brush.FieldGroups or {}) do if IsValid(group) then
            if not group.FieldReady or (ply and not group.FieldPreparedClients[ply]) then return false end
        end end
        return true
    end
    local function retireForPlayer(wall,ply)
        if not wall.FieldReady or not IsValid(ply) then return end
        for _,brush in ipairs(wall.SourceBrushes) do
            local native=IsValid(brush) and brush.FieldNative
            if IsValid(native) and sourceReady(brush,ply) then native:SetPreventTransmit(ply,true) end
        end
    end
    function R.Register(brush)
        nativeFor(brush) brush:SetSolid(SOLID_NONE) brush:SetNoDraw(true)
        timer.Create('rf_geomod_field_bootstrap',.2,1,guarded(R.Bootstrap))
    end
    local function spawnChunk(wall,chunk)
        local ent=ents.Create('rf_geomod_field_chunk')
        ent:SetPos(vector_origin) ent:Spawn() ent.GeoModProxy=wall
        ent:SetNWEntity('rf_geomod_field_group',wall)
        ent:SetNWInt('rf_geomod_field_serial',wall.FieldSerial)
        RFMapProtection.Apply(ent,wall.FieldData.config)
        wall.FieldChunks[chunk.key]=ent wall:DeleteOnRemove(ent)
        return ent
    end
    local function create(part)
        local wall=ents.Create('rf_geomod_field')
        R.serial=R.serial+1 wall.FieldSerial=R.serial
        wall.FieldData=part.data wall.FieldVolume=part.volume wall.InitialPieces=part.volume.pieces
        wall.FieldData.cache_key=C.Key(part.data,part.volume)
        wall.FieldCache={contours=0,restored_chunks=0,restored_render=0}
        wall.SourceBrushes=part.sourceBrushes wall.FieldChunks={} wall.Cuts={} wall.Revision=0
        wall.FieldPreparedClients={}
        wall.Hardness=part.data.config.hardness wall.CutMaterialName=part.data.config.cut_material
        wall.CutRepeat=part.data.config.cut_repeat wall.WallMaterialNames=part.data.materials
        wall:SetPos(vector_origin) wall:Spawn() wall:SetNWInt('rf_geomod_field_serial',wall.FieldSerial)
        local low,high=G.Bounds(wall.InitialPieces) wall.Low,wall.High=low,high wall:SetCollisionBounds(low,high)
        RFMapProtection.Apply(wall,part.data.config) R.groups[wall]=true
        for brush in pairs(part.brushes) do
            brush.GeoModProxy=wall brush.FieldGroups=brush.FieldGroups or {} brush.FieldGroups[wall]=true
            local native=nativeFor(brush) native.GeoModProxy=wall native:SetOwner(wall)
            native:SetNWEntity('rf_geomod_field_group',wall)
            native:SetNWInt('rf_geomod_field_serial',wall.FieldSerial)
        end
        push(wall,function(job,checkpoint)
            for _,chunk in ipairs(wall.FieldVolume:AllChunks()) do spawnChunk(wall,chunk) checkpoint() end
            wall.FieldCatalogReady=true
            R.Send(wall)
            local base,source=C.LoadGeometry(wall,checkpoint) wall.FieldCache.geometry=source or 'built'
            local boundary=not base and G.AuthoredBoundary(wall.FieldVolume,checkpoint)
            for _,chunk in ipairs(wall.FieldVolume:AllChunks()) do
                buildChunk(wall,chunk,checkpoint,base and base[chunk.key],nil,boundary)
            end
            if not base then wall.FieldCache.saved_geometry=C.SaveGeometry(wall,checkpoint) end
            wall.FieldReady=true
            for _,brush in ipairs(wall.SourceBrushes) do
                local native=IsValid(brush) and brush.FieldNative
                if IsValid(native) and sourceReady(brush) then native:SetNotSolid(true) native:SetSolid(SOLID_NONE) end
            end
            for ply in pairs(wall.FieldPreparedClients) do retireForPlayer(wall,ply) end
            R.Send(wall)
        end)
        return wall
    end
    function R.Bootstrap()
        local brushes=ents.FindByClass('func_geomod')
        table.sort(brushes,function(a,b) return a:MapCreationID()<b:MapCreationID() end)
        local missing={} for _,brush in ipairs(brushes) do if not IsValid(brush.GeoModProxy) then missing[#missing+1]=brush end end
        if #missing==0 then return end
        push(nil,function(_,checkpoint)
            local parts=G.FieldSources.Partitions(missing)
            for _,part in ipairs(parts) do create(part) checkpoint() end
            hook.Run('RFGeoModStaticSourcesRegistered')
        end)
    end
    local function retireNative(wall)
        for _,brush in ipairs(wall.SourceBrushes) do
            if IsValid(brush) and IsValid(brush.FieldNative) then brush.FieldNative:Remove() brush.FieldNative=nil end
        end
    end

    local function isMapSolid(ent)
        return IsValid(ent) and not G.IsWall(ent) and (ent:GetSolid()==SOLID_BSP or
            (ent:CreatedByMap() and ent:GetMoveType()==MOVETYPE_NONE))
    end

    local function supported(wall,pieces,visited,checkpoint)
        visited[wall]=true
        local neighbors={}
        for _,piece in ipairs(pieces) do
            for _,face in ipairs(piece.faces) do
                if face.mat~=1 then
                    local center=Vector()
                    for _,p in ipairs(face.points) do center=center+p end
                    center=center/#face.points
                    for index=0,#face.points do
                        local p=index==0 and center or (center+face.points[index])/2
                        local trace=util.TraceLine({start=p-face.normal*.2,endpos=p+face.normal*.8,mask=MASK_SOLID,
                            filter=function(e)
                                local neighbor=G.WallFor(e)
                                return (R.groups[neighbor] and not visited[neighbor]) or isMapSolid(e)
                            end})
                        if trace.HitWorld or isMapSolid(trace.Entity) then return true end
                        local neighbor=G.WallFor(trace.Entity)
                        if R.groups[neighbor] then neighbors[neighbor]=true end
                    end
                    checkpoint()
                end
            end
        end
        for neighbor in pairs(neighbors) do
            if not visited[neighbor] and supported(neighbor,neighbor.DetachPieces or neighbor.InitialPieces,visited,checkpoint) then return true end
        end
        return false
    end

    local function containsMapSolid(pieces)
        -- A pillar can run through an island's opening without touching any
        -- of its faces. Keep the island if its interior bounds aren't clear.
        local low,high=G.Bounds(pieces)
        local center=(low+high)/2
        local half=(high-low)/2
        local inset=Vector(math.min(half.x/2,.125),math.min(half.y/2,.125),math.min(half.z/2,.125))
        local trace=util.TraceHull({start=center,endpos=center,mins=-half+inset,maxs=half-inset,mask=MASK_SOLID,
            filter=isMapSolid})
        return trace.StartSolid or trace.Hit
    end

    local function detachUnsupported(wall,checkpoint)
        if not wall.DetachAnchor or not G.SpawnDetachedWall then return end
        local history=wall.Cuts
        local pieces=mirrorPieces(wall,history,#history,checkpoint)
        if not pieces then return end
        local children={}
        local islands=G.Islands(pieces,nil,checkpoint)
        for _,island in ipairs(islands) do
            local members={}
            for _,index in ipairs(island.indices) do members[#members+1]=pieces[index] end
            if #children<8 and not containsMapSolid(members) and not supported(wall,members,{},checkpoint) then
                local child=G.SpawnDetachedWall(wall,island,members)
                if IsValid(child) then
                    children[#children+1]=child
                    history[#history+1]={center=island.centroid,detach=true}
                end
            end
        end
        if #children==0 then return end
        local volume=wall.FieldVolume
        for i=#history-#children+1,#history do
            local remaining,detached=mirrorPieces(wall,history,i,checkpoint)
            G.DropAuthoredIsland(volume,remaining,detached,checkpoint)
        end
        wall.Revision=volume.revision
        R.Send(wall)
        local boundary=G.AuthoredBoundary(volume,checkpoint)
        for _,chunk in ipairs(volume:AllChunks()) do
            buildChunk(wall,chunk,checkpoint,nil,nil,boundary)
            checkpoint()
        end
        hook.Run('RFGeoModGeometryChanged',wall)
        for _,child in ipairs(children) do
            local phys=IsValid(child) and child:GetPhysicsObject()
            if IsValid(phys) then phys:EnableMotion(true) phys:Wake() end
        end
    end

    function R.Carve(point,normal,radius,seed,effectOrigin,atOrigin,scorchOrigin)
        normal=normal:GetNormalized()
        radius=math.Clamp(tonumber(radius) or 52,6,150)
        seed=seed or math.random(1,2147483646)
        local center=atOrigin and point or point+normal*radius*.4
        center=Vector(math.Round(center.x*8)/8,math.Round(center.y*8)/8,math.Round(center.z*8)/8)
        local candidates={}
        for wall in pairs(R.groups) do if IsValid(wall) then
            local scaled=math.Round(radius*G.HardnessCraterScale(wall.Hardness)*8)/8
            local bound=scaled*2
            local low,high=wall.Low,wall.High
            if center.x+bound>=low.x and center.x-bound<=high.x and center.y+bound>=low.y and center.y-bound<=high.y and
                center.z+bound>=low.z and center.z-bound<=high.z then
                candidates[#candidates+1]={wall=wall,radius=scaled}
            end
        end end
        if #candidates==0 then return false end
        push(nil,function(job,checkpoint)
            -- Publish each accepted polygon cut before uploading its physics.
            -- Clients can rebuild their own meshes while the server uploads.
            local accepted={}
            for _,candidate in ipairs(candidates) do
                local wall,r=candidate.wall,candidate.radius
                if IsValid(wall) then
                    local began=job:Time()
                    local op={center=center,radius=r,seed=seed,normal=normal,scorch_origin=scorchOrigin}
                    local removed,changed=G.CutAuthoredBoundary(wall.FieldVolume,op,checkpoint)
                    if changed>0 then
                        retireNative(wall)
                        wall.Cuts[#wall.Cuts+1]=op
                        wall.Revision=wall.FieldVolume.revision
                        R.Send(wall)
                        accepted[#accepted+1]={wall=wall,dirty=0,changed=changed,r=r,cpu=job:Time()-began,removed=removed}
                    end
                end
            end
            for _,cut in ipairs(accepted) do if IsValid(cut.wall) then
                local began=job:Time()
                local wall=cut.wall
                local boundary=G.AuthoredBoundary(wall.FieldVolume,checkpoint)
                for _,chunk in ipairs(wall.FieldVolume:AllChunks()) do
                    local _,rebuilt=buildChunk(wall,chunk,checkpoint,nil,nil,boundary)
                    if rebuilt then cut.dirty=cut.dirty+1 end
                    checkpoint()
                end
                cut.cpu=cut.cpu+job:Time()-began
            end end
            for _,cut in ipairs(accepted) do if IsValid(cut.wall) then
                local wall=cut.wall
                if wall.DetachAnchor==nil then
                    wall.DetachAnchor=supported(wall,wall.InitialPieces,{},checkpoint)
                end
                detachUnsupported(wall,checkpoint)
            end end
            for _,cut in ipairs(accepted) do if IsValid(cut.wall) then
                local wall=cut.wall
                wall.LastFieldCut={changed=cut.changed,dirty=cut.dirty,cpu_ms=cut.cpu*1000,revision=wall.Revision}
                hook.Run('RFGeoModGeometryChanged',wall)
                if G.EmitDestruction then
                    G.EmitDestruction(wall,effectOrigin or point,normal,cut.r,cut.removed,checkpoint)
                end
            end end
        end,nil,false,true)
        return true
    end
    R.recent={}
    function R.Blast(position,normal,radius,inflictor,originIsCenter,hit)
        local key=tostring(inflictor)..':'..engine.TickCount()..':'..math.Round(position.x*8)..':'..math.Round(position.y*8)..':'..math.Round(position.z*8)
        if R.recent[key] then return false end
        R.recent[key]=true timer.Simple(.1,function() R.recent[key]=nil end)
        if IsValid(inflictor) then inflictor.RFFieldBlastTick=engine.TickCount() end
        -- A blast without a GeoMod contact projects from its origin onto each
        -- facing wall. Its force or floor normal still orients the cutter.
        local scorchOrigin=not R.groups[G.WallFor(hit)] and position or nil
        return R.Carve(position,normal,radius,nil,position,originIsCenter,scorchOrigin)
    end
    function R.Damage(wall,info)
        wall.DamageEvents=(wall.DamageEvents or 0)+1
        if not (info:IsExplosionDamage() or info:IsDamageType(DMG_BLAST_SURFACE)) then return end
        local inflictor=info:GetInflictor()
        if IsValid(inflictor) and inflictor.RFFieldBlastTick==engine.TickCount() then return end
        local crater=IsValid(inflictor) and inflictor.RFGeoModCraterRadius or 0
        local damage=info:GetDamage()
        local position=info:GetDamagePosition()
        if position:LengthSqr()==0 and IsValid(inflictor) and not inflictor:IsWorld() then position=inflictor:GetPos() end
        if crater<=0 and IsValid(inflictor) and inflictor:GetClass()=='rpg_missile' then
            -- RadiusDamage can notify distant chunks before the contact chunk.
            -- Recover the missile's own hit before the first callback claims it.
            local step=inflictor:GetForward()*8
            local missilePosition=inflictor:GetPos()
            local hit=util.TraceLine({start=missilePosition-step,endpos=missilePosition+step,
                mask=MASK_SHOT,filter={inflictor,inflictor:GetOwner()}})
            if hit.Hit and not hit.StartSolid and R.groups[G.WallFor(hit.Entity)] then
                local fullDamage=tonumber(inflictor:GetInternalVariable('m_flDamage'))
                if fullDamage and fullDamage>0 then damage=fullDamage end
                if damage>=10 then
                    R.Blast(hit.HitPos,hit.HitNormal,G.BlastRadius(damage),inflictor,false,hit.Entity)
                    return
                end
            end
        end
        if damage<10 and crater<=0 then return end
        local normal=info:GetDamageForce():GetNormalized() if normal:LengthSqr()<.5 then normal=vector_up end
        R.Blast(position,normal,crater>0 and crater or G.BlastRadius(damage),inflictor,true)
    end
    function R.Removed(wall)
        C.Cancel(wall)
        if wall.SourceBrushes then retireNative(wall) end
        R.groups[wall]=nil
    end
    function R.Reset()
        R.generation=R.generation+1 R.queue={} R.active=nil
        for wall in pairs(R.groups) do if IsValid(wall) then wall:Remove() end end R.groups={}
        for _,brush in ipairs(ents.FindByClass('func_geomod')) do brush.GeoModProxy=nil brush.FieldGroups={} nativeFor(brush) end
        R.Bootstrap()
    end
    net.Receive(MSG..'_request',function(_,ply)
        -- Each answer re-encodes every field wall, so limit each player to one
        -- answer per window. A new player starts with no cooldown.
        if (ply.RFGeoModStaticNext or 0)>CurTime() then return end
        ply.RFGeoModStaticNext=CurTime()+2
        for wall in pairs(R.groups) do if IsValid(wall) and next(wall.FieldChunks or {}) then R.Send(wall,ply) end end
    end)
    net.Receive(MSG..'_ready',function(_,ply)
        local wall=net.ReadEntity() local serial=net.ReadUInt(32)
        if not IsValid(wall) or not R.groups[wall] or wall.FieldSerial~=serial then return end
        wall.FieldPreparedClients[ply]=true
        retireForPlayer(wall,ply)
    end)
    hook.Add('Think','rf_geomod_field_jobs',guarded(function() step(.002) end))
    -- All authored sources exist here. The registration debounce uses simulation
    -- time, which can remain paused for seconds during listen-server startup.
    -- Queue preparation now; keep the normal bounded Think worker and the
    -- debounce for sources registered later or after map cleanup.
    hook.Add('InitPostEntity','rf_geomod_field_bootstrap',guarded(function()
        timer.Remove('rf_geomod_field_bootstrap')
        R.Bootstrap()
    end))
    hook.Add('PostCleanupMap','rf_geomod_field_cleanup',function()
        R.generation=R.generation+1 R.queue={} R.active=nil R.groups={}
        timer.Create('rf_geomod_field_bootstrap',.2,1,guarded(R.Bootstrap))
    end)
else
    local function retireClientNative(wall,state)
        if not state.initialReady then return end
        -- A PVS-dependent brush may arrive after the always-transmitted field
        -- chunks. Retry until it exists, and reject reused entity indices.
        for _,desc in ipairs(state.nativeSources or state.data.sources) do
            local native=Entity(desc.native or 0)
            if IsValid(native) and native:GetClass()=='func_brush' then
                local ready,owned=true,false
                for _,owner in ipairs(desc.native_owners or {{wall:EntIndex(),state.data.serial}}) do
                    local group=Entity(owner[1]) local other=R.states[group]
                    if not IsValid(group) or group:GetNWInt('rf_geomod_field_serial')~=owner[2] or not other or not other.initialReady then ready=false end
                    if native:GetNWEntity('rf_geomod_field_group')==group and native:GetNWInt('rf_geomod_field_serial')==owner[2] then owned=true end
                end
                if ready and owned then native:SetNoDraw(true) end
            end
        end
    end
    local function acknowledgeReady(wall,state)
        if state.retirementSent then return end
        net.Start(MSG..'_ready') net.WriteEntity(wall) net.WriteUInt(state.data.serial,32) net.SendToServer()
        state.retirementSent=true
    end
    local function apply(data)
        local wall=Entity(data.entity)
        if not IsValid(wall) or wall:GetNWInt('rf_geomod_field_serial')~=data.serial then return false end
        local state=R.states[wall]
        if state then state.nativeSources=data.sources end
        if state and state.initialReady and wall.LocalRevision==data.revision then
            retireClientNative(wall,state) acknowledgeReady(wall,state) return true
        end
        if not state then
            state={data=data,applied=0,initialReady=false,queued=false} R.states[wall]=state
            wall.FieldClientState=state wall.FieldChunks={} wall.CutMaterialName=data.config.cut_material
            wall.FieldData=data wall.FieldCache={contours=0,restored_chunks=0,restored_render=0}
            wall.RenderMatrix=Matrix()
            wall.Cuts={} wall.CutRepeat=data.config.cut_repeat wall.WallMaterialNames=data.materials
        end
        state.latest=data
        if not state.queued then
            state.queued=true
            local live=state.initialReady
            push(wall,function(_,checkpoint)
                if not wall.FieldVolume then
                    wall.FieldVolume=G.FieldSources.Build(data)
                    wall.InitialPieces=wall.FieldVolume.pieces
                    wall.Low,wall.High=G.Bounds(wall.InitialPieces) wall:SetCollisionBounds(wall.Low,wall.High)
                    state.baseTriangles={}
                    for _,face in ipairs(wall.FieldVolume.exterior or {}) do
                        local original=face.origin_face or face
                        if not original.nodraw then
                            local vertices={}
                            for i=2,#face.points-1 do for _,p in ipairs({face.points[1],face.points[i],face.points[i+1]}) do vertices[#vertices+1]={pos=p,normal=face.normal} end end
                            state.baseTriangles[#state.baseTriangles+1]=vertices
                        end
                    end
                    wall.RenderRevision=1
                    state.baseGeometry,wall.FieldCache.geometry=C.LoadGeometry(wall,checkpoint)
                    state.baseRender,wall.FieldCache.render=C.LoadRender(wall,checkpoint)
                    wall.FieldCache.geometry=wall.FieldCache.geometry or 'built'
                    wall.FieldCache.render=wall.FieldCache.render or 'built'
                end
                while state.latest do
                    local snapshot=state.latest state.latest=nil
                    for key,index in pairs(snapshot.chunks) do
                        while not IsValid(Entity(index)) or Entity(index):GetNWInt('rf_geomod_field_serial')~=snapshot.serial do coroutine.yield() end
                        wall.FieldChunks[key]=Entity(index) Entity(index).GeoModProxy=wall
                    end
                    local chunks=wall.FieldVolume:AllChunks()
                    if not state.initialReady and #snapshot.history>0 and (not state.baseGeometry or not state.baseRender) then
                        -- A first-time late join still saves the pristine base.
                        -- Prepare CPU data only: never display intact geometry in destroyed areas.
                        local buffers={}
                        local boundary=not state.baseGeometry and G.AuthoredBoundary(wall.FieldVolume,checkpoint)
                        for _,c in ipairs(chunks) do
                            local row=state.baseGeometry and state.baseGeometry[c.key]
                            local triangles=row and row.triangles or boundary[c.key] or {}
                            if not state.baseGeometry then wall.FieldVolume.chunks[c.key]={triangles=triangles,revision=0} end
                            if not state.baseRender then
                                wall.FieldProgress={key=c.key,stage='initial render cache'}
                                buffers[c.key]=G.FieldRender.Prepare(wall,{},triangles,checkpoint,true)
                            end
                            checkpoint()
                        end
                        if not state.baseGeometry then C.SaveGeometry(wall,checkpoint) state.baseGeometry=wall.FieldVolume.chunks end
                        if not state.baseRender then
                            C.SaveRender(wall,checkpoint,buffers) state.baseRender={}
                            for key,b in pairs(buffers) do state.baseRender[key]=b.batches end
                        end
                    end
                    for i=state.applied+1,#snapshot.history do
                        local op=snapshot.history[i]
                        if op.detach then
                            local remaining,detached=mirrorPieces(wall,snapshot.history,i,checkpoint)
                            assert(remaining and detached,'Could not replay a detached GeoMod island')
                            G.DropAuthoredIsland(wall.FieldVolume,remaining,detached,checkpoint)
                        else
                            G.CutAuthoredBoundary(wall.FieldVolume,op,checkpoint,true)
                        end
                        state.applied=i checkpoint()
                    end
                    wall.Cuts=snapshot.history
                    local initial=not state.initialReady and state.applied==0
                    local boundary=not (initial and state.baseGeometry) and G.AuthoredBoundary(wall.FieldVolume,checkpoint)
                    for _,chunk in ipairs(chunks) do
                        if IsValid(wall.FieldChunks[chunk.key]) then
                            buildChunk(wall,chunk,checkpoint,initial and state.baseGeometry and state.baseGeometry[chunk.key],
                                initial and state.baseRender and state.baseRender[chunk.key],boundary)
                        end
                        checkpoint()
                    end
                    if not state.initialReady and wall.FieldVolume.revision==0 then
                        if not state.baseGeometry then wall.FieldCache.saved_geometry=C.SaveGeometry(wall,checkpoint) end
                        if not state.baseRender then wall.FieldCache.saved_render=C.SaveRender(wall,checkpoint) end
                    end
                    state.baseGeometry=nil state.baseRender=nil
                    state.initialReady=true wall.LocalRevision=snapshot.revision wall.RenderRevision=wall.RenderRevision+1
                    state.nativeSources=snapshot.sources
                    retireClientNative(wall,state) acknowledgeReady(wall,state)
                    if G.RebuildWallDecals then G.RebuildWallDecals(wall) end
                end
                state.queued=false
            end,nil,false,live)
        end
        return true
    end
    net.Receive(MSG,function()
        local data=util.JSONToTable(util.Decompress(net.ReadData(net.ReadUInt(16))))
        for _,op in ipairs(data.history) do
            op.center=Vector(unpack(op.center))
            if op.normal then op.normal=Vector(unpack(op.normal)) end
            if op.scorch_origin then op.scorch_origin=Vector(unpack(op.scorch_origin)) end
        end
        R.pending[data.serial]=data
    end)
    function R.Removed(wall)
        C.Cancel(wall)
        R.states[wall]=nil if G.ClearWallDecals then G.ClearWallDecals(wall) end
    end
    local requested=0
    hook.Add('Think','rf_geomod_field_jobs',guarded(function()
        for serial,data in pairs(R.pending) do if apply(data) then R.pending[serial]=nil end end
        step(.004)
        for wall,state in pairs(R.states) do if IsValid(wall) then retireClientNative(wall,state) end end
        if RealTime()>requested then requested=RealTime()+5 net.Start(MSG..'_request') net.SendToServer() end
    end))
    hook.Add('PostDrawOpaqueRenderables','rf_geomod_field_decals',function(depth,_,sky3d)
        if depth or sky3d then return end
        for wall,state in pairs(R.states) do if IsValid(wall) and wall.RenderRevision then
            for decal in pairs(wall.GeoModDecals or {}) do if IsValid(decal) then decal:DrawGeoModDecal() end end
            if G.DrawWallDecals then G.DrawWallDecals(wall) end
        end end
    end)
    local preparingAt,completedAt,wasBuilding,nextCheck,lastProgress=nil,nil,false,0,nil
    hook.Add('Think','rf_geomod_field_preparation',function()
        local now=SysTime() if now<nextCheck then return end nextCheck=now+.1
        local walls=ents.FindByClass('rf_geomod_field') local ready,building=0,false
        for _,wall in ipairs(walls) do
            if wall.FieldClientState and wall.FieldClientState.initialReady then ready=ready+1 end
            local cache=wall.FieldCache
            if cache and (cache.geometry=='built' or cache.render=='built') then building=true end
        end
        if #walls==0 then
            preparingAt=nil completedAt=nil wasBuilding=false lastProgress=nil return
        end
        if ready==#walls then
            if not preparingAt then return end
            if R.active or #R.queue>0 or next(R.pending) then return end
            completedAt=completedAt or now
            -- Confirm the initial group catalogue has settled, but report the
            -- readiness time before the settle check.
            if now-completedAt<.25 then return end
            MsgN(string.format('[GeoMod] Geometry %s in %.2f seconds',wasBuilding and 'built' or 'loaded',completedAt-preparingAt))
            preparingAt=nil completedAt=nil wasBuilding=false lastProgress=nil return
        end
        preparingAt=preparingAt or now completedAt=nil wasBuilding=wasBuilding or building
        local progress=string.format('[GeoMod] %s geometry: %d/%d',wasBuilding and 'Building' or 'Loading',ready,#walls)
        if progress~=lastProgress then
            MsgN(progress)
            lastProgress=progress
        end
    end)
end
