include('shared.lua')
include('rf_geomod/surface.lua')
include('rf_geomod/scorch.lua')

local G=RFGeoMod
local materials={}
local shadowMaterial=Material('models/debug/debugwhite')
local depthFlags=bit.bor(STUDIO_SHADOWDEPTHTEXTURE or 0,STUDIO_SSAODEPTHTEXTURE or 0)
local function wallMaterial(path)
    if not materials[path] then
        local texture=Material(path):GetTexture('$basetexture')
        materials[path]=CreateMaterial('rf_geomod_movable_'..util.CRC(path),'VertexLitGeneric',{
            ['$basetexture']=texture and texture:GetName() or 'dev/dev_measurewall01a',
            ['$nocull']='0'})
    end
    return materials[path]
end

function ENT:Initialize()
    self:SetModel('models/hunter/blocks/cube025x025x025.mdl')
    self:ApplyWallConfiguration({})
    self.Cuts={} self.Pieces={} self:SetSolid(SOLID_NONE)
    self:ConfigureBounds()
    self:DrawShadow(false)
end

local function freeMeshes(bundle)
    if not bundle then return end
    for _,mesh in ipairs(bundle.meshes) do mesh:Destroy() end
    for _,group in ipairs(bundle.scorch) do group.mesh:Destroy() end
    if bundle.shadow then bundle.shadow.Mesh:Destroy() end
    for _,mesh in ipairs(bundle.shadowVolume and bundle.shadowVolume.meshes or {}) do mesh:Destroy() end
end

function ENT:GenerateMeshes(job,checkpoint)
    local renderBundle=job.bundle
    local triangles={}
    local scorchPlanes={}
    local cuts=G.CutsInFinalFrame(job.cuts)
    for i=1,#job.materials do triangles[i]={} end
    for _,polygon in ipairs(job.pieces) do
        local face=polygon.face
        if not face or not face.nodraw then
            local n,points=polygon.normal,polygon.points
            local mat=face and face.mat or 1
            local repeatSize=mat==1 and self.CutRepeat or self.SurfaceRepeat
            local u=n:Cross(Vector(0,0,1))
            if u:LengthSqr()<.1 then u=Vector(1,0,0) else u:Normalize() end
            local v=n:Cross(u)
            local tex=face and face.uv
            local scorch
            if mat~=1 and #cuts>0 then
                local d=n:Dot(points[1])
                local key=string.format('%.4f,%.4f,%.4f,%.3f',n.x,n.y,n.z,d)
                scorch=scorchPlanes[key]
                if scorch==nil then
                    local passes=G.ScorchPasses(cuts,n,d)
                    scorch=#passes>0 and {vertices={},passes=passes} or false
                    scorchPlanes[key]=scorch
                end
            end
            local vertices=triangles[mat+1]
            local function add(p)
                local tu,tv=p:Dot(u)/repeatSize,p:Dot(v)/repeatSize
                if tex then tu=(p:Dot(tex.u)+tex.uo)/tex.width tv=(p:Dot(tex.v)+tex.vo)/tex.height end
                vertices[#vertices+1]={pos=p,normal=n,u=tu,v=tv,color=color_white}
                if scorch then
                    scorch.vertices[#scorch.vertices+1]={pos=p,normal=n,u=p:Dot(u),v=p:Dot(v),color=color_white}
                end
            end
            for i=2,#points-1 do add(points[1]) add(points[i+1]) add(points[i]) end
        end
        checkpoint()
    end
    local total=0
    for i,path in ipairs(job.materials) do
        local mat=wallMaterial(path)
        local mesh=Mesh(mat)
        renderBundle.meshes[i]=mesh
        if #triangles[i]>0 then mesh:BuildFromTriangles(triangles[i]) end
        total=total+#triangles[i]
        checkpoint()
    end
    -- Projected-light depth passes can use the same shape as one opaque mesh.
    -- Ordinary map shadows are drawn from the triangles in shadows.lua.
    if total>0 and total<=65535 then
        local vertices={}
        for _,list in ipairs(triangles) do
            for i,vertex in ipairs(list) do
                vertices[#vertices+1]=vertex
                if i%512==0 then checkpoint() end
            end
        end
        local mesh=Mesh(shadowMaterial)
        mesh:BuildFromTriangles(vertices)
        renderBundle.shadow={Mesh=mesh,Material=shadowMaterial}
    end
    for _,entry in pairs(scorchPlanes) do if entry then
        entry.mesh=Mesh(G.GetScorchMaterial())
        renderBundle.scorch[#renderBundle.scorch+1]=entry
        entry.mesh:BuildFromTriangles(entry.vertices)
        entry.vertices=nil
        checkpoint()
    end end
    return triangles,total
end

local CUBE_DIRECTIONS={Vector(1,0,0),Vector(-1,0,0),Vector(0,1,0),Vector(0,-1,0),Vector(0,0,1),Vector(0,0,-1)}
function ENT:UpdateLightCube()
    if self.LightCube and (self.NextLightCube or 0)>RealTime() then return end
    -- Resting walls rarely change lighting; moving ones refresh quickly.
    self.NextLightCube=RealTime()+(self:GetVelocity():LengthSqr()>1 and 0.1 or 1)
    local low,high=self.Low or Vector(),self.High or Vector()
    local center,extent=(low+high)*0.5,(high-low)*0.45
    -- Average a few points through the wall, skipping any inside solid world
    -- (which samples as black), so one bad point cannot darken the wall.
    local samples={}
    for _,offset in ipairs({Vector(),Vector(extent.x,0,0),Vector(-extent.x,0,0),Vector(0,extent.y,0),
        Vector(0,-extent.y,0),Vector(0,0,extent.z),Vector(0,0,-extent.z)}) do
        local point=self:LocalToWorld(center+offset)
        if bit.band(util.PointContents(point),CONTENTS_SOLID)==0 then samples[#samples+1]=point end
    end
    if #samples==0 then samples[1]=self:LocalToWorld(center) end
    local cube={}
    for i,direction in ipairs(CUBE_DIRECTIONS) do
        local sum=Vector()
        for _,point in ipairs(samples) do sum=sum+render.ComputeLighting(point,direction) end
        cube[i]=sum/#samples
    end
    self.LightCube=cube
end


function ENT:GetRenderMesh()
    return self.RenderBundle and self.RenderBundle.shadow
end

function ENT:DrawWallSurface()
    local bundle=self.RenderBundle
    for i,mesh in ipairs(bundle.meshes) do
        if #self.RenderTriangles[i]>0 then
            render.SetMaterial(wallMaterial(bundle.materials[i])) mesh:Draw()
        end
    end
end

function ENT:Draw(flags)
    local bundle=self.RenderBundle
    if not bundle then return end
    if flags and bit.band(flags,depthFlags)~=0 and bundle.shadow then
        self:DrawModel(flags)
        return
    end
    self.RenderMatrix=self:GetWorldTransformMatrix()
    self:UpdateLightCube()
    local function drawMesh() self:DrawWallSurface() end
    cam.PushModelMatrix(self.RenderMatrix)
    render.SuppressEngineLighting(true)
    render.SetLocalModelLights()
    for i,color in ipairs(self.LightCube) do render.SetModelLighting(i-1,color.x,color.y,color.z) end
    drawMesh()
    render.SuppressEngineLighting(false)
    render.RenderFlashlights(drawMesh)
    G.DrawScorches(self,bundle.scorch)
    cam.PopModelMatrix()
    for decal in pairs(self.GeoModDecals or {}) do
        if IsValid(decal) then
            if decal.BuiltRenderRevision~=self.RenderRevision then decal:Think() end
            decal:DrawGeoModDecal()
        end
    end
    if G.DrawWallDecals then G.DrawWallDecals(self) end
end

function ENT:Think()
    local physics=self:GetPhysicsObject()
    if IsValid(physics) then physics:SetPos(self:GetPos()) physics:SetAngles(self:GetAngles()) end
    if not self.PendingSnapshot and not self.ActiveSnapshot and self.LocalRevision~=self:GetNWInt('rf_geomod_revision')
        and (self.NextStateRequest or 0)<CurTime() then
        self.NextStateRequest=CurTime()+1
        net.Start('rf_geomod_request') net.WriteEntity(self) net.SendToServer()
    end
end

function ENT:OnRemove()
    freeMeshes(self.BuildingBundle)
    freeMeshes(self.RenderBundle)
    if G.ClearWallDecals then G.ClearWallDecals(self) end
end

local function copyArray(items)
    local copy={}
    for i,item in ipairs(items) do copy[i]=item end
    return copy
end

local function applySnapshot(ent,snapshot,job,checkpoint)
    local sourceModel,config,cuts=snapshot.source,snapshot.config,snapshot.cuts
    local dynamic,box,payload=snapshot.dynamic,snapshot.box,snapshot.payload
    if not box and not sourceModel and not payload and not ent.SeedPieces then return end
    local started=job:Time()
    local modeChanged=ent.DynamicWall~=dynamic or ent.BoxSource~=box
    ent.DynamicWall,ent.BoxSource=dynamic,box
    if payload and not ent.SeedPieces then
        ent.SeedPieces,ent.SeedMaterials=G.UnpackMovableSeed(payload)
        if not ent.SeedPieces then ErrorNoHalt('[GeoMod] Could not decode detached wall\n') return end
    end
    local configChanged=ent:ApplyWallConfiguration(config) or ent.BrushSourceModel~=sourceModel or modeChanged
    if configChanged or not ent.InitialPieces then
        local loaded,err=ent:LoadWallSource(sourceModel)
        if not loaded then ErrorNoHalt('[GeoMod] '..tostring(err)..'\n') return end
    end
    local previous=ent.Cuts or {}
    local prefix=not configChanged and ent.LocalRevision~=nil and #cuts>=#previous
    if prefix then for i,old in ipairs(previous) do
        local cut=cuts[i]
        local oldRam,newRam=old.ram,cut.ram
        if old.kind~=cut.kind or old.center:DistToSqr(cut.center)>0.000001 or old.seed~=cut.seed or
                old.radius~=cut.radius or old.bore~=cut.bore or
                (oldRam==nil)~=(newRam==nil) or
                (oldRam and newRam and (oldRam.right~=newRam.right or oldRam.half~=newRam.half or oldRam.travel~=newRam.travel)) or
                (old.normal and old.normal:DistToSqr(cut.normal)>0.000001) then
            prefix=false break
        end
    end end
    local first=prefix and #previous+1 or 1
    local pieces=prefix and ent.Pieces or ent.InitialPieces
    local seed=not prefix and pieces or nil
    local firstSurfaceCut=first
    for i=first,#cuts do
        local op=cuts[i]
        pieces=G.ApplyOp(pieces,op,checkpoint)
        if not pieces then break end
        if op.kind~=G.OP_CUT then
            seed=pieces
            firstSurfaceCut=i+1
        end
    end
    ent.LastClientCSGMs=(job:Time()-started)*1000
    ent.LastReplayedCuts=#cuts-first+1 ent.LastReplayIncremental=prefix
    if not pieces then ErrorNoHalt('[GeoMod] Snapshot replay failed\n') return end
    local boundary
    if seed then
        boundary=G.NewLocalBoundary(seed,checkpoint)
    else
        local old=ent.CutBoundary
        local state=old.authoredBoundary
        boundary={pieces=old.pieces,exterior=old.exterior,queryCuts=copyArray(old.queryCuts),revision=old.revision,
            authoredBoundary={shapes=state.shapes,cuts=copyArray(state.cuts),triangles={},dirty={}}}
    end
    for i=firstSurfaceCut,#cuts do G.CutAuthoredBoundary(boundary,cuts[i],checkpoint,true) end

    local mesh={pieces=G.AuthoredPolygons(boundary,checkpoint),cuts=cuts,
        materials=ent.WallMaterialNames,bundle={meshes={},scorch={},materials=ent.WallMaterialNames}}
    ent.BuildingBundle=mesh.bundle
    local meshStarted=job:Time()
    local triangles,count=ent:GenerateMeshes(mesh,checkpoint)
    ent.LightBuildMs=(job:Time()-meshStarted)*1000
    if not ent:BuildPhysics(pieces,checkpoint) then
        freeMeshes(mesh.bundle)
        ent.BuildingBundle=nil
        ErrorNoHalt('[GeoMod] Client collision rebuild failed\n')
        return
    end
    freeMeshes(ent.RenderBundle)
    ent.BuildingBundle=nil
    ent.RenderBundle,ent.RenderTriangles=mesh.bundle,triangles
    if mesh.bundle.shadow then ent:UpdateShadow() end
    ent.RenderStats={triangles=count/3}
    ent.Cuts,ent.Pieces,ent.CutBoundary=cuts,pieces,boundary
    ent.LocalRevision,ent.RenderRevision=snapshot.revision,snapshot.revision
    ent.LastSnapshotMs=(job:Time()-started)*1000
end

net.Receive('rf_geomod_state',function()
    local ent,revision=net.ReadEntity(),net.ReadUInt(16)
    local sourceModel=net.ReadString() if sourceModel=='' then sourceModel=nil end
    local dynamic,box=net.ReadBool(),net.ReadBool()
    local seedSize=net.ReadUInt(16)
    local payload=seedSize>0 and net.ReadData(seedSize)
    local config={mins=net.ReadVector(),maxs=net.ReadVector(),surface_material=net.ReadString(),
        cut_material=net.ReadString(),surface_repeat=net.ReadFloat(),cut_repeat=net.ReadFloat()}
    local count=net.ReadUInt(10)
    local cuts={} for i=1,count do
        local kind=net.ReadUInt(2)
        local op={kind=kind,center=net.ReadVector()}
        if kind==RFGeoMod.OP_CUT then
            op.radius,op.seed=net.ReadFloat(),net.ReadUInt(16)
            op.normal=Vector(net.ReadFloat(),net.ReadFloat(),net.ReadFloat())
            op.bore=net.ReadBool()
            if net.ReadBool() then
                op.ram={right=Vector(net.ReadFloat(),net.ReadFloat(),net.ReadFloat()),
                    half=Vector(net.ReadFloat(),net.ReadFloat(),net.ReadFloat()),
                    travel=Vector(net.ReadFloat(),net.ReadFloat(),net.ReadFloat())}
            end
        end
        cuts[i]=op
    end
    if not IsValid(ent) or ent:GetClass()~='rf_geomod_dynamic' then return end

    local latest=ent.PendingSnapshot or ent.ActiveSnapshot
    local previous=latest and latest.revision or ent.LocalRevision
    if previous then
        local advance=(revision-previous)%65536
        if advance==0 or advance>=32768 then return end
    end
    local pending=ent.PendingSnapshot
    ent.PendingSnapshot={revision=revision,source=sourceModel,dynamic=dynamic,box=box,
        payload=payload or (pending and pending.payload),config=config,cuts=cuts}
    if pending then return end
    G.ScheduleCut(ent,function(job,checkpoint)
        local snapshot=ent.PendingSnapshot
        ent.PendingSnapshot=nil
        ent.ActiveSnapshot=snapshot
        applySnapshot(ent,snapshot,job,checkpoint)
        ent.ActiveSnapshot=nil
    end,function(job)
        ent.LastMeshBuildStats={cpu_ms=job.cpu*1000,max_step_ms=job.max_step*1000,steps=job.steps,
            elapsed_ms=(SysTime()-job.scheduledAt)*1000,revision=ent.LocalRevision}
    end,function()
        ent.ActiveSnapshot=nil
        freeMeshes(ent.BuildingBundle)
        ent.BuildingBundle=nil
    end)
end)
