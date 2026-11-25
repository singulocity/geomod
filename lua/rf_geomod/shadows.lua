-- RF-137: dynamic shadows received by GeoMod surfaces.
-- Source projects render-to-texture shadows onto world brushes and static props
-- only. GeoMod draws its walls and replaced map brushes as Lua meshes, so player,
-- NPC and prop shadows never land on them. This pass does the same job itself:
-- each nearby caster is drawn as a white silhouette into a cell of a shared
-- atlas, looking along the map's shadow direction, and the GeoMod triangles
-- inside that caster's shadow volume are drawn again with the cell projected on
-- them, darkening the surface underneath. The silhouette is redrawn every frame
-- (animation); the projected geometry is rebuilt only when the caster leaves its
-- snapped tile or a receiving surface changes.
RFGeoMod=RFGeoMod or {}
local G=RFGeoMod

if SERVER then
    -- The shadow_control settings are parsed server-side; publish them.
    local settings={}
    hook.Add('EntityKeyValue','rf_geomod_shadow_control',function(ent,key,value)
        if ent:GetClass()~='shadow_control' then return end
        settings[string.lower(key)]=value
    end)
    local function publish()
        local angles=settings.angles and Vector(settings.angles)
        local direction=angles and Angle(angles.x,angles.y,angles.z):Forward() or Vector(0,0,-1)
        local r,g,b=string.match(settings.color or '','(%d+)%s+(%d+)%s+(%d+)')
        SetGlobal2Vector('RFGeoModShadowDir',direction)
        SetGlobal2Float('RFGeoModShadowColor',r and (tonumber(r)+tonumber(g)+tonumber(b))/3 or 64)
        SetGlobal2Float('RFGeoModShadowDistance',tonumber(settings.distance) or 50)
        SetGlobal2Bool('RFGeoModShadowDisabled',settings.disableallshadows=='1')
    end
    hook.Add('InitPostEntity','rf_geomod_shadow_control',publish)
    hook.Add('PostCleanupMap','rf_geomod_shadow_control',publish)
    return
end

local enabled=CreateClientConVar('rf_geomod_shadows','1',true,false,'Draw dynamic GeoMod shadows.',0,1)
local rShadows=GetConVar('r_shadows')
local debugView=CreateClientConVar('rf_geomod_shadows_debug','0',false,false,'Draw the GeoMod shadow overlay unblended.',0,1)
local GRID=8                    -- silhouette cells per atlas side
local MAX_CASTERS=GRID*GRID
local RANGE=2500                -- casters farther from the view are skipped
local SNAP=16                   -- tile snapping and padding: rebuilds only when a caster crosses it
local BIAS=0.25                 -- lift above the receiving face against z-fighting
local neutralTone=Vector(1,1,1)
local BUILDS_PER_FRAME=4        -- nearest casters first; the rest build on later frames
-- Like the engine: any model entity casts unless it disabled its shadow
-- (DrawShadow(false) sets EF_NOSHADOW). These never cast on their own.
local SKIP_CLASSES={viewmodel=true,gmod_hands=true,predicted_viewmodel=true,
    rf_geomod_dynamic=true,rf_geomod_field=true,rf_geomod_field_chunk=true,rf_geomod_debris=true}

-- Silhouette size per caster. Native shadows use a texture fitted tightly to
-- each caster; ours is padded for tile reuse, so it needs more pixels to match.
local resolution=CreateClientConVar('rf_geomod_shadows_resolution','256',true,false,
    'Pixels per GeoMod shadow silhouette (64, 128, 256 or 512).',64,512)
local silhouette=CreateMaterial('rf_geomod_shadow_caster','UnlitGeneric',{
    ['$basetexture']='vgui/white',['$model']='1',['$nofog']='1'})
local volumeMaterial=CreateMaterial('rf_geomod_shadow_volume','UnlitGeneric',{
    ['$basetexture']='vgui/white',['$nofog']='1'})
-- Edge softness: each silhouette is copied into its atlas cell four times with
-- small sub-pixel offsets and alpha 1, 1/2, 1/3, 1/4, which leaves the average
-- of the four (a small box blur). An earlier version multiplied four offset
-- copies of the projected geometry over a silhouette holding the 4th root of its
-- grey; the root pushed fading shadows so close to white that they vanished
-- mid-fade. (render.BlurRenderTarget disturbed the frame buffer, and
-- $basetexturetransform on the receiver material did not apply.)
-- Radius in silhouette pixels at 128 px, scaled with the resolution.
local blur=CreateClientConVar('rf_geomod_shadows_blur','0.3',true,false,'Softness of GeoMod shadow edges (0 = hard).',0,8)
local SOFT_OFFSETS={{1,0},{-1,0},{0,1},{0,-1}}
-- Silhouettes are rasterized without anti-aliasing, so their edges stair-step;
-- blurring only smears the steps. With supersampling each silhouette is drawn
-- at twice the cell size into a scratch target and shrunk into its cell, where
-- bilinear filtering averages each 2x2 block (true 2x2 anti-aliasing).
-- Native shadows last somewhat beyond the map's shadow_control distance before
-- fading out completely; 1.3 matched them on Coffee Break (user tuning, RF-137).
local FADE_SCALE=1.3

-- The native RTT path draws the backing studio model, which is only a tiny
-- cube. Extrude the real light-facing triangles instead. Each closed prism
-- contributes to the stencil winding even where volumes overlap or the view
-- enters the shadow. The scene depth already includes slopes and props.
function G.WallShadowPrisms(groups,direction,reach,emit)
    local near,far=direction*.15,direction*reach
    for _,vertices in ipairs(groups) do
        for i=1,#vertices-2,3 do
            if vertices[i].normal:Dot(direction)<-.001 then
                local a,b,c=vertices[i].pos,vertices[i+1].pos,vertices[i+2].pos
                local A,B,C=a+far,b+far,c+far
                a,b,c=a+near,b+near,c+near
                emit(a,b,c,C,B,A,
                    b,a,A,b,A,B,
                    c,b,B,c,B,C,
                    a,c,C,a,C,A)
            end
        end
    end
end

local function wallShadowVolume(ent,direction,reach)
    local bundle=ent.RenderBundle
    if not bundle or not ent.RenderTriangles then return end
    local localDirection=ent:WorldToLocal(ent:GetPos()+direction):GetNormalized()
    local old=bundle.shadowVolume
    if old and old.reach==reach and old.direction:DistToSqr(localDirection)<.000025 then return old.meshes end
    local size=ent.High-ent.Low
    local depth=math.abs(localDirection.x)*size.x+math.abs(localDirection.y)*size.y+math.abs(localDirection.z)*size.z
    local meshes,positions={},{}
    local function flush()
        if #positions==0 then return end
        local result=Mesh(volumeMaterial)
        mesh.Begin(result,MATERIAL_TRIANGLES,#positions/3)
        for _,position in ipairs(positions) do
            mesh.Position(position)
            mesh.TexCoord(0,0,0)
            mesh.AdvanceVertex()
        end
        mesh.End()
        meshes[#meshes+1]=result
        positions={}
    end
    G.WallShadowPrisms(ent.RenderTriangles,localDirection,reach+depth,function(...)
        for i=1,24 do positions[#positions+1]=select(i,...) end
        if #positions>=60000 then flush() end
    end)
    flush()
    if old then for _,m in ipairs(old.meshes) do m:Destroy() end end
    bundle.shadowVolume={meshes=meshes,reach=reach,direction=localDirection}
    return meshes
end

local function drawWallShadows()
    local eye=EyePos()
    local direction=GetGlobal2Vector('RFGeoModShadowDir',Vector(0,0,-1)):GetNormalized()
    if direction:LengthSqr()<.5 then return end
    local reach=GetGlobal2Float('RFGeoModShadowDistance',50)*FADE_SCALE
    local shade=math.Clamp(255-GetGlobal2Float('RFGeoModShadowColor',64),0,217)
    if reach<=0 or shade<=0 then return end
    local draws,walls={},{}
    for _,ent in ipairs(ents.FindByClass('rf_geomod_dynamic')) do
        if ent.RenderBundle and not ent:IsDormant() and not ent:GetNoDraw() and ent:GetPos():DistToSqr(eye)<RANGE*RANGE then
            local matrix=ent:GetWorldTransformMatrix()
            walls[#walls+1]={ent=ent,matrix=matrix}
            local meshes=wallShadowVolume(ent,direction,reach)
            if meshes and #meshes>0 then draws[#draws+1]={meshes=meshes,matrix=matrix} end
        end
    end
    if #draws==0 then return end
    render.ClearStencil()
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilReferenceValue(0)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_KEEP)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.OverrideColorWriteEnable(true,false)
    render.OverrideAlphaWriteEnable(true,false)
    render.OverrideDepthEnable(true,false)
    render.SetMaterial(volumeMaterial)
    local function drawFaces(cull,operation)
        render.CullMode(cull)
        render.SetStencilZFailOperation(operation)
        for _,draw in ipairs(draws) do
            cam.PushModelMatrix(draw.matrix)
            for _,m in ipairs(draw.meshes) do m:Draw() end
            cam.PopModelMatrix()
        end
    end
    drawFaces(MATERIAL_CULLMODE_CCW,STENCIL_INCR)
    drawFaces(MATERIAL_CULLMODE_CW,STENCIL_DECR)
    render.CullMode(MATERIAL_CULLMODE_CCW)
    -- Give the caster surface priority over its volume. Where a prism side
    -- lies on the wall face (common on axis-aligned walls), their depths can
    -- quantize differently. Clear the mask only on visible wall pixels so
    -- that disagreement cannot flash on the wall or erase a ground shadow.
    render.SetStencilZFailOperation(STENCIL_KEEP)
    render.SetStencilPassOperation(STENCIL_ZERO)
    for _,wall in ipairs(walls) do
        cam.PushModelMatrix(wall.matrix)
        wall.ent:DrawWallSurface()
        cam.PopModelMatrix()
    end
    render.SetStencilPassOperation(STENCIL_KEEP)
    render.OverrideDepthEnable(false)
    render.OverrideColorWriteEnable(false)
    render.OverrideAlphaWriteEnable(false)
    render.SetStencilCompareFunction(STENCIL_NOTEQUAL)
    cam.Start2D()
    surface.SetDrawColor(0,0,0,shade)
    surface.DrawRect(0,0,ScrW(),ScrH())
    cam.End2D()
    render.SetStencilEnable(false)
    render.ClearStencil()
end
local supersample=CreateClientConVar('rf_geomod_shadows_supersample','1',true,false,'Anti-alias GeoMod shadow edges (2x2 supersampling).',0,1)
local CELL,atlas,projected,scratch,scratchMaterial
local function useResolution()
    local size=2^math.Clamp(math.Round(math.log(math.max(resolution:GetInt(),1))/math.log(2)),6,9)
    if size==CELL then return end
    CELL=size
    atlas=GetRenderTargetEx('rf_geomod_shadow_atlas_'..size,size*GRID,size*GRID,RT_SIZE_NO_CHANGE,
        MATERIAL_RT_DEPTH_SEPARATE,bit.bor(4,8,256),0,IMAGE_FORMAT_RGB888) -- clamp s/t, no mips
    projected=CreateMaterial('rf_geomod_shadow_receiver_'..size,'UnlitGeneric',{
        ['$basetexture']=atlas:GetName(),['$nofog']='1',['$translucent']='1'})
    scratch=GetRenderTargetEx('rf_geomod_shadow_scratch_'..size*2,size*2,size*2,RT_SIZE_NO_CHANGE,
        MATERIAL_RT_DEPTH_SEPARATE,bit.bor(4,8,256),0,IMAGE_FORMAT_RGB888)
    scratchMaterial=CreateMaterial('rf_geomod_shadow_scratch_'..size*2,'UnlitGeneric',{
        ['$basetexture']=scratch:GetName(),['$nofog']='1',['$ignorez']='1',['$vertexcolor']='1',['$vertexalpha']='1',['$translucent']='1'})
end
useResolution()

local casters={}   -- entity -> {cell, key, mesh, window}
local freeCells={}
for i=MAX_CASTERS-1,0,-1 do freeCells[#freeCells+1]=i end

local function basis(direction)
    local angles=direction:Angle()
    return angles:Right(),angles:Up(),angles
end

-- Receivers: toolgun/detached walls and replaced map brushes (field chunks),
-- each cached as world-space triangles plus a world AABB.
local function receiverStamp(ent)
    if ent:GetClass()=='rf_geomod_dynamic' then
        if not ent.RenderBundle or not ent.RenderTriangles then return end
        local p,a=ent:GetPos(),ent:GetAngles()
        return string.format('%s|%.2f,%.2f,%.2f|%.2f,%.2f,%.2f',tostring(ent.RenderBundle),p.x,p.y,p.z,a.p,a.y,a.r)
    end
    local wall=ent.GeoModProxy
    local state=IsValid(wall) and wall.FieldClientState
    if not state or not state.initialReady or not ent.FieldRenderBundle then return end
    return tostring(ent.FieldRenderBundle)
end

-- World AABB only: cheap enough to keep for every receiver on the map.
function G.MovableShadowBounds(low,high,toWorld)
    local minimum,maximum=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    for _,x in ipairs({low.x,high.x}) do
        for _,y in ipairs({low.y,high.y}) do
            for _,z in ipairs({low.z,high.z}) do
                local p=toWorld(Vector(x,y,z))
                minimum.x,minimum.y,minimum.z=math.min(minimum.x,p.x),math.min(minimum.y,p.y),math.min(minimum.z,p.z)
                maximum.x,maximum.y,maximum.z=math.max(maximum.x,p.x),math.max(maximum.y,p.y),math.max(maximum.z,p.z)
            end
        end
    end
    return minimum,maximum
end

local function receiverBounds(ent,stamp)
    local cache=ent.RFShadowBounds
    if cache and cache.stamp==stamp then return cache end
    local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    if ent:GetClass()=='rf_geomod_dynamic' then
        -- The receiver is the cut render mesh. Use its local bounds and
        -- transform, including when a very tall wall is rotated into a floor.
        local matrix=ent:GetWorldTransformMatrix()
        low,high=G.MovableShadowBounds(ent.Low,ent.High,function(point) return matrix*point end)
    else
        for _,list in pairs(ent.FieldVertices or {}) do
            for _,vertex in ipairs(list) do
                local p=vertex.pos
                low.x,low.y,low.z=math.min(low.x,p.x),math.min(low.y,p.y),math.min(low.z,p.z)
                high.x,high.y,high.z=math.max(high.x,p.x),math.max(high.y,p.y),math.max(high.z,p.z)
            end
        end
    end
    cache={stamp=stamp,low=low,high=high}
    ent.RFShadowBounds=cache
    return cache
end

-- World-space triangles, built only for receivers a shadow volume reaches.
local function receiverData(ent,stamp)
    local cache=ent.RFShadowReceiver
    if cache and cache.stamp==stamp then return cache end
    local positions,normals={},{}
    local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    local function add(list,toWorld,rotate)
        for i=1,#list-2,3 do
            local n=rotate and rotate(list[i].normal) or list[i].normal
            normals[#normals+1]=n
            for k=0,2 do
                local p=toWorld and toWorld(list[i+k].pos) or list[i+k].pos
                positions[#positions+1]=p
                low.x,low.y,low.z=math.min(low.x,p.x),math.min(low.y,p.y),math.min(low.z,p.z)
                high.x,high.y,high.z=math.max(high.x,p.x),math.max(high.y,p.y),math.max(high.z,p.z)
            end
        end
    end
    if ent:GetClass()=='rf_geomod_dynamic' then
        local matrix=ent:GetWorldTransformMatrix()
        local origin=matrix:GetTranslation()
        local function toWorld(p) return matrix*p end
        local function rotate(n) return (matrix*n-origin):GetNormalized() end
        for _,list in ipairs(ent.RenderTriangles) do add(list,toWorld,rotate) end
    else
        for _,list in pairs(ent.FieldVertices or {}) do add(list) end
    end
    cache={stamp=stamp,positions=positions,normals=normals,low=low,high=high}
    ent.RFShadowReceiver=cache
    return cache
end

local function boxesOverlap(aLow,aHigh,bLow,bHigh)
    return aLow.x<=bHigh.x and aHigh.x>=bLow.x and aLow.y<=bHigh.y and aHigh.y>=bLow.y and aLow.z<=bHigh.z and aHigh.z>=bLow.z
end

-- Map chunks rarely change: index them in a coarse grid, refreshed when a
-- chunk is published or cleared (and every few seconds as a fallback for the
-- initial handoff), so each caster only tests the chunks near it. Movable walls are few
-- and are restamped every frame.
local CELL_SIZE=256
local index={time=-math.huge,grid={},count=0,revision=-1}
local function cellKey(x,y,z) return ((x+4096)*8192+(y+4096))*8192+(z+4096) end
local function refreshIndex()
    local grid,count={},0
    for wall in pairs(G.Static and G.Static.states or {}) do
        for _,ent in pairs(IsValid(wall) and wall.FieldChunks or {}) do
            local stamp=IsValid(ent) and receiverStamp(ent)
            if stamp then
                local bounds=receiverBounds(ent,stamp)
                local r={ent=ent,stamp=stamp,low=bounds.low,high=bounds.high}
                count=count+1
                for x=math.floor(r.low.x/CELL_SIZE),math.floor(r.high.x/CELL_SIZE) do
                    for y=math.floor(r.low.y/CELL_SIZE),math.floor(r.high.y/CELL_SIZE) do
                        for z=math.floor(r.low.z/CELL_SIZE),math.floor(r.high.z/CELL_SIZE) do
                            local key=cellKey(x,y,z)
                            local cell=grid[key] if not cell then cell={} grid[key]=cell end
                            cell[#cell+1]=r
                        end
                    end
                end
            end
        end
    end
    index.grid,index.count,index.time,index.revision=grid,count,RealTime(),G.FieldRenderRevision or 0
end

local function movableReceivers()
    local list={}
    for _,ent in ipairs(ents.FindByClass('rf_geomod_dynamic')) do
        local stamp=receiverStamp(ent)
        if stamp then
            local bounds=receiverBounds(ent,stamp)
            list[#list+1]={ent=ent,stamp=stamp,low=bounds.low,high=bounds.high}
        end
    end
    return list
end

local function receiversIn(low,high,movable)
    local hits,seen={},{}
    for x=math.floor(low.x/CELL_SIZE),math.floor(high.x/CELL_SIZE) do
        for y=math.floor(low.y/CELL_SIZE),math.floor(high.y/CELL_SIZE) do
            for z=math.floor(low.z/CELL_SIZE),math.floor(high.z/CELL_SIZE) do
                for _,r in ipairs(index.grid[cellKey(x,y,z)] or {}) do
                    if not seen[r] and boxesOverlap(low,high,r.low,r.high) then seen[r]=true hits[#hits+1]=r end
                end
            end
        end
    end
    for _,r in ipairs(movable) do
        if boxesOverlap(low,high,r.low,r.high) then hits[#hits+1]=r end
    end
    return hits
end


local function clip(points,axis,limit,sign,world)
    local output={}
    for i,a in ipairs(points) do
        local b=points[i%#points+1]
        local da,db=sign*((world and a.p or a)[axis]-limit),sign*((world and b.p or b)[axis]-limit)
        if da<=0 then output[#output+1]=a end
        if (da<0 and db>0) or (da>0 and db<0) then
            local t=da/(da-db)
            output[#output+1]={u=a.u+(b.u-a.u)*t,v=a.v+(b.v-a.v)*t,d=a.d+(b.d-a.d)*t,p=a.p+(b.p-a.p)*t}
        end
    end
    return output
end

-- The caster's shadow volume in the (u, v, d) frame of the shadow direction.
-- Built from the bounding sphere, so a spinning pickup keeps the same tile and
-- its projected geometry is not rebuilt every frame.
local function volume(ent,u,v,direction,distance)
    local center,radius=ent:WorldSpaceCenter(),math.max(ent:BoundingRadius(),1)
    local cu,cv,cd=center:Dot(u),center:Dot(v),center:Dot(direction)
    local window=math.ceil((2*radius+2*SNAP)/SNAP)*SNAP
    return {cu=math.Round(cu/SNAP)*SNAP,cv=math.Round(cv/SNAP)*SNAP,window=window,
        near=math.floor((cd-radius)/16)*16,far=math.ceil((cd+radius+distance)/16)*16}
end

function G.ShadowHasFootprintContact(ground,low,high)
    -- The light ray through the centre can miss a narrow ledge or pass
    -- through a hole even while the prop rests on the remaining surface.
    -- Limit the fallback to the contact slab so a nearby ledge above the
    -- prop or well below it cannot reset the normal distance fade.
    for _,triangle in ipairs(ground) do
        local polygon=clip(triangle,'z',low.z+2,1,true)
        if #polygon>=3 then polygon=clip(polygon,'z',low.z-4,-1,true) end
        if #polygon>=3 then polygon=clip(polygon,'x',low.x,-1,true) end
        if #polygon>=3 then polygon=clip(polygon,'x',high.x,1,true) end
        if #polygon>=3 then polygon=clip(polygon,'y',low.y,-1,true) end
        if #polygon>=3 then polygon=clip(polygon,'y',high.y,1,true) end
        for i=2,#polygon-1 do
            local normal=(polygon[i].p-polygon[1].p):Cross(polygon[i+1].p-polygon[1].p)
            if math.abs(normal.z)>.001 then return true end
        end
    end
    return false
end

local function volumeBox(vol,u,v,direction)
    local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    local h=vol.window/2
    for _,a in ipairs({vol.cu-h,vol.cu+h}) do for _,b in ipairs({vol.cv-h,vol.cv+h}) do for _,c in ipairs({vol.near,vol.far}) do
        local p=u*a+v*b+direction*c
        low.x,low.y,low.z=math.min(low.x,p.x),math.min(low.y,p.y),math.min(low.z,p.z)
        high.x,high.y,high.z=math.max(high.x,p.x),math.max(high.y,p.y),math.max(high.z,p.z)
    end end end
    return low,high
end

local function build(entry,vol,list,u,v,direction)
    if entry.mesh then entry.mesh:Destroy() entry.mesh=nil end
    local h=vol.window/2
    local cellX,cellY=entry.cell%GRID,math.floor(entry.cell/GRID)
    local vertices={}
    local surface=math.huge
    local ground={} -- receiving triangles in (u, v, d), for the height under the caster
    for _,r in ipairs(list) do
        local data=r.data
        local positions,normals=data.positions,data.normals
        for t=1,#normals do
            local n=normals[t]
            if n:Dot(direction)<-0.05 then
                local points={}
                local inside=true
                local minU,maxU,minV,maxV,minD,maxD=math.huge,-math.huge,math.huge,-math.huge,math.huge,-math.huge
                for k=1,3 do
                    local p=positions[(t-1)*3+k]
                    local pu,pv,pd=p:Dot(u),p:Dot(v),p:Dot(direction)
                    minU,maxU,minV,maxV=math.min(minU,pu),math.max(maxU,pu),math.min(minV,pv),math.max(maxV,pv)
                    minD,maxD=math.min(minD,pd),math.max(maxD,pd)
                    points[k]={u=pu,v=pv,d=pd,p=p}
                end
                if maxU<vol.cu-h or minU>vol.cu+h or maxV<vol.cv-h or minV>vol.cv+h or maxD<vol.near or minD>vol.far then inside=false end
                if inside then
                    points=clip(points,'u',vol.cu+h,1) if #points>=3 then points=clip(points,'u',vol.cu-h,-1) end
                    if #points>=3 then points=clip(points,'v',vol.cv+h,1) end
                    if #points>=3 then points=clip(points,'v',vol.cv-h,-1) end
                    if #points>=3 then points=clip(points,'d',vol.near,-1) end
                    if #points>=3 then points=clip(points,'d',vol.far,1) end
                    if #points>=3 then
                        local lift=n*BIAS
                        local function emit(q)
                            local s=(q.u-(vol.cu-h))/vol.window
                            local tt=((vol.cv+h)-q.v)/vol.window
                            surface=math.min(surface,q.d)
                            vertices[#vertices+1]={pos=q.p+lift,u=(cellX+s)/GRID,v=(cellY+tt)/GRID}
                        end
                        for i=2,#points-1 do
                            emit(points[1]) emit(points[i]) emit(points[i+1])
                            ground[#ground+1]={points[1],points[i],points[i+1]}
                        end
                    end
                end
            end
        end
    end
    entry.vertices=0
    entry.surface=surface
    entry.ground=ground
    if #vertices==0 then return end
    local result=Mesh(projected)
    mesh.Begin(result,MATERIAL_TRIANGLES,#vertices/3)
    for _,q in ipairs(vertices) do
        mesh.Position(q.pos) mesh.TexCoord(0,q.u,q.v) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
    end
    mesh.End()
    entry.mesh=result
    entry.vertices=#vertices
end

local function release(ent)
    local entry=casters[ent]
    if not entry then return end
    if entry.mesh then entry.mesh:Destroy() end
    freeCells[#freeCells+1]=entry.cell
    casters[ent]=nil
end

local function modelEntity(ent)
    local model=string.lower(ent:GetModel() or '')
    return string.sub(model,-4)=='.mdl' and not SKIP_CLASSES[ent:GetClass()]
end

local function isCaster(ent,eye)
    if not IsValid(ent) or ent:IsDormant() or ent:GetNoDraw() or ent:IsEffectActive(EF_NOSHADOW) then return false,'hidden or no shadow' end
    if ent:GetPos():DistToSqr(eye)>RANGE*RANGE then return false,'too far' end
    if not modelEntity(ent) then return false,'not a model' end
    if ent:IsPlayer() then
        -- Like the engine, your own shadow only shows when your model is drawn.
        if ent==LocalPlayer() and not ent:ShouldDrawLocalPlayer() then return false,'local player not drawn' end
        return ent:Alive(),'dead player'
    end
    if ent:IsWeapon() and IsValid(ent:GetOwner()) then return false,'held weapon' end
    -- Bone-merged attachments are drawn with their parent's silhouette only
    -- when they are a player's or NPC's weapon; other children cast themselves.
    if ent:IsEffectActive(EF_BONEMERGE) then return false,'bone merged' end
    return true
end

-- Possible casters, tracked as entities appear instead of searched each frame.
local pool={}
local function consider(ent)
    if IsValid(ent) and modelEntity(ent) then pool[ent]=true end
end
hook.Add('OnEntityCreated','rf_geomod_shadows',function(ent) timer.Simple(0,function() consider(ent) end) end)
hook.Add('InitPostEntity','rf_geomod_shadows',function() for _,ent in ents.Iterator() do consider(ent) end end)
for _,ent in ents.Iterator() do consider(ent) end

-- Red Faction NPCs are NextBots that carry a lowered weapon even while it is
-- not active; its client render origin is kept at the hand (RF-141).
local function heldWeapon(ent)
    local weapon=ent.GetRFWeapon and ent:GetRFWeapon()
    if IsValid(weapon) then return weapon end
    return ent.GetActiveWeapon and ent:GetActiveWeapon()
end

-- Sandbox's spawn effect swaps in a RenderOverride whose overlay draws the
-- model with a refraction material (a copy of the screen) from the player's
-- eye and then clears the material override, which put a coloured image of
-- the caster into its silhouette. Draw the plain model instead.
local function drawPlain(ent)
    local override=ent.SpawnEffect and ent.RenderOverride
    if override then ent.RenderOverride=nil end
    ent:DrawModel()
    if override then ent.RenderOverride=override end
end

local function drawSilhouette(ent)
    drawPlain(ent)
    -- RF NPCs expose GetRFWeapon (their lowered weapon is not "active").
    if ent:IsPlayer() or ent:IsNPC() or ent.GetRFWeapon then
        local weapon=heldWeapon(ent)
        if IsValid(weapon) and not weapon:IsDormant() and not weapon:GetNoDraw() then weapon:DrawModel() end
    end
end

-- Distance from the caster's lowest point down to the receiving surface under
-- its centre: our own projected triangles first, then the world for casters
-- whose centre is over native floor.
function G.ShadowReceiverDepth(ground,foot,u,v,direction)
    local bottom=foot:Dot(direction)
    local cu,cv=foot:Dot(u),foot:Dot(v)
    local best
    for _,tri in ipairs(ground) do
        local a,b,c=tri[1],tri[2],tri[3]
        local det=(b.v-c.v)*(a.u-c.u)+(c.u-b.u)*(a.v-c.v)
        if math.abs(det)>1e-6 then
            local l1=((b.v-c.v)*(cu-c.u)+(c.u-b.u)*(cv-c.v))/det
            local l2=((c.v-a.v)*(cu-c.u)+(a.u-c.u)*(cv-c.v))/det
            local l3=1-l1-l2
            if l1>=-1e-3 and l2>=-1e-3 and l3>=-1e-3 then
                local d=l1*a.d+l2*b.d+l3*c.d
                if d>=bottom-2 and (not best or d<best) then best=d end
            end
        end
    end
    return best,bottom
end

local function groundGap(ent,entry,u,v,direction,reach)
    local low,high=ent:WorldSpaceAABB()
    local center=ent:WorldSpaceCenter()
    -- Start the fade ray at the caster's base. Measuring from its base but
    -- sampling through its centre biases the gap on an angled light.
    local foot=Vector(center.x,center.y,low.z)
    local best,bottom=G.ShadowReceiverDepth(entry.ground,foot,u,v,direction)
    if (not best or best-bottom>4) and G.ShadowHasFootprintContact(entry.ground,low,high) then return 0 end
    if not best then
        local start=foot-direction*2
        local trace=util.TraceLine({start=start,endpos=foot+direction*reach,
            mask=MASK_SOLID_BRUSHONLY})
        if not trace.Hit then return math.huge end
        best=trace.HitPos:Dot(direction)
    end
    return math.max(best-bottom,0)
end

local lastFrame=-1
local active={}
local stats={ms=0,average=0,peak=0,casters=0,rebuilds=0}
local diagnostics={}
local probes=setmetatable({},{__mode='k'})
local function update(eye)
    useResolution()
    active={}
    diagnostics={}
    if not enabled:GetBool() or (rShadows and not rShadows:GetBool()) or GetGlobal2Bool('RFGeoModShadowDisabled',false) then
        for ent in pairs(casters) do release(ent) end
        return
    end
    local t0=SysTime()
    if index.revision~=(G.FieldRenderRevision or 0) or RealTime()-index.time>5 then refreshIndex() end
    local movable=movableReceivers()
    stats.receivers=index.count+#movable stats.t_receivers=(SysTime()-t0)*1000
    if stats.receivers==0 then for ent in pairs(casters) do release(ent) end return end
    local direction=GetGlobal2Vector('RFGeoModShadowDir',Vector(0,0,-1)) direction:Normalize()
    local distance=GetGlobal2Float('RFGeoModShadowDistance',50)
    -- Source darkens a shadowed surface towards the shadow color.
    local strength=1-math.Clamp(GetGlobal2Float('RFGeoModShadowColor',64)/255,0,1)
    strength=math.Clamp(strength,0,0.85)
    local u,v,angles=basis(direction)
    -- Settings that change the projected geometry belong in the tile key, or a
    -- caster that is standing still would keep geometry built for old settings.
    local frameKey=string.format('%d|%.3f,%.3f,%.3f|%.2f|%d,%.2f',index.revision,direction.x,direction.y,direction.z,strength,CELL,blur:GetFloat())
    local t1=SysTime()
    local candidates={}
    for ent in pairs(pool) do
        if isCaster(ent,eye) then candidates[#candidates+1]=ent end
    end
    table.sort(candidates,function(a,b) return a:GetPos():DistToSqr(eye)<b:GetPos():DistToSqr(eye) end)
    stats.candidates=#candidates stats.t_candidates=(SysTime()-t1)*1000 local t2=SysTime()
    local seen,builds={},0
    for _,ent in ipairs(candidates) do
        if #active>=MAX_CASTERS then break end
        -- Entities may ask for a longer reach, as pickups do with SetShadowCastDistance.
        local reach=math.max(distance,ent.RFShadowDistance or 0)*FADE_SCALE
        local vol=volume(ent,u,v,direction,reach)
        -- Static props and hovering pickups keep their tile: reuse the receiver
        -- query and key until the tile or any receiver changes.
        local tile=string.format('%d,%d,%d,%d,%d|%s',vol.cu,vol.cv,vol.window,vol.near,vol.far,frameKey)
        local probe=probes[ent]
        if not probe or probe.tile~=tile then
            local low,high=volumeBox(vol,u,v,direction)
            local hits=receiversIn(low,high,{})
            -- The key names the tile and the chunks it reaches, not the global
            -- revision: a chunk rebuilt elsewhere does not rebuild this caster.
            local stamps={string.format('%d,%d,%d,%d,%d|%.3f,%.3f,%.3f|%.2f|%.1f|%d,%.2f',vol.cu,vol.cv,vol.window,vol.near,vol.far,
                direction.x,direction.y,direction.z,strength,reach,CELL,blur:GetFloat())}
            for _,r in ipairs(hits) do stamps[#stamps+1]=r.stamp end
            probe={tile=tile,hits=hits,key=table.concat(stamps,';'),low=low,high=high}
            probes[ent]=probe
        end
        -- Movable walls are few: test them every frame, keyed by their own stamps.
        local hits,key=probe.hits,probe.key
        if #movable>0 then
            hits={} for i,r in ipairs(probe.hits) do hits[i]=r end
            local extra={}
            for _,r in ipairs(movable) do
                if boxesOverlap(probe.low,probe.high,r.low,r.high) then hits[#hits+1]=r extra[#extra+1]=r.stamp end
            end
            if #extra>0 then key=key..';'..table.concat(extra,';') end
        end
        diagnostics[ent]={hits=#hits}
        if #hits>0 then
            local entry=casters[ent]
            if not entry and #freeCells>0 then
                entry={cell=table.remove(freeCells)} casters[ent]=entry
            end
            if entry then
                seen[ent]=true
                if entry.key~=key and builds<BUILDS_PER_FRAME then
                    builds=builds+1
                    entry.key=key
                    stats.rebuilds=stats.rebuilds+1
                    local data={}
                    for i,hit in ipairs(hits) do data[i]={data=receiverData(hit.ent,hit.stamp)} end
                    build(entry,vol,data,u,v,direction)
                    -- The silhouette is drawn in the tile its geometry was built for;
                    -- a deferred rebuild keeps projecting correctly from the old tile.
                    entry.vol=vol
                end
                if entry.mesh then
                    -- One darkness per caster, fading as it rises over the surface
                    -- straight under it along the shadow direction (Source fades
                    -- shadows over their distance). The nearest surface anywhere in
                    -- the window made shadows pop in at full strength when a higher
                    -- ledge nearby was in range.
                    local gap=groundGap(ent,entry,u,v,direction,reach)
                    local shade=strength*(1-math.Clamp(gap/math.max(reach,1),0,1))
                    diagnostics[ent].shade,diagnostics[ent].vertices,diagnostics[ent].gap=shade,entry.vertices,gap
                    if shade>0.01 then active[#active+1]={ent=ent,entry=entry,gray=1-shade} end
                end
            end
        end
    end
    for ent in pairs(casters) do if not seen[ent] then release(ent) end end
    stats.t_volumes=(SysTime()-t2)*1000
    if #active==0 then return end
    -- These render targets store shadow multipliers. Scene auto-exposure
    -- would brighten the silhouette and wash out the shadow on the receiver.
    local sceneTone=render.GetToneMappingScaleLinear()
    render.SetToneMappingScaleLinear(neutralTone)
    -- Silhouettes: a grey caster (1 - darkness) on white, one ortho cell each.
    local smooth=supersample:GetBool()
    local function silhouetteView(a,x,y,size)
        local vol=a.entry.vol
        local h=vol.window/2
        cam.Start({type='3D',x=x,y=y,w=size,h=size,
            origin=u*vol.cu+v*vol.cv+direction*(vol.near-8),angles=angles,znear=1,zfar=vol.far-vol.near+16,
            ortho={left=-h,right=h,top=-h,bottom=h}})
        render.SetColorModulation(a.gray,a.gray,a.gray)
        drawSilhouette(a.ent)
        cam.End3D()
    end
    render.PushRenderTarget(atlas)
    render.Clear(255,255,255,255,true,true)
    render.PopRenderTarget()
    render.SuppressEngineLighting(true)
    render.SetBlend(1)
    -- Draw into the scratch target (twice the cell size when supersampling),
    -- then copy into the cell: shrinking averages each 2x2 block, and the
    -- blur taps average four sub-pixel shifted copies.
    local size=smooth and CELL*2 or CELL
    local extent=size/(CELL*2)
    local shift=blur:GetFloat()/128*extent -- blur in 128 px units, as scratch UV
    local taps=shift>0 and SOFT_OFFSETS or {{0,0}}
    for _,a in ipairs(active) do
        local cell=a.entry.cell
        local x,y=(cell%GRID)*CELL,math.floor(cell/GRID)*CELL
        render.PushRenderTarget(scratch)
        render.Clear(255,255,255,255,true,true)
        render.MaterialOverride(silhouette)
        silhouetteView(a,0,0,size)
        render.MaterialOverride()
        render.SetColorModulation(1,1,1)
        render.PopRenderTarget()
        render.PushRenderTarget(atlas)
        cam.Start2D()
        surface.SetMaterial(scratchMaterial)
        for k,offset in ipairs(taps) do
            local du,dv=offset[1]*shift,offset[2]*shift
            surface.SetDrawColor(255,255,255,math.Round(255/k))
            surface.DrawTexturedRectUV(x,y,CELL,CELL,du,dv,extent+du,extent+dv)
        end
        cam.End2D()
        render.PopRenderTarget()
    end
    render.SuppressEngineLighting(false)
    render.SetToneMappingScaleLinear(sceneTone)
end

-- Build the atlas from the main view before water renders. A reflection can
-- draw opaque entities first, with a skybox origin and a water clip plane.
hook.Add('RenderScene','rf_geomod_shadows',function(origin)
    local frame=FrameNumber()
    if frame==lastFrame then return end
    lastFrame=frame
    local started=SysTime()
    update(origin)
    stats.ms=(SysTime()-started)*1000 stats.casters=#active
    stats.average=stats.average*0.95+stats.ms*0.05 stats.peak=math.max(stats.peak,stats.ms)
end)

-- Multiply the surface by the atlas: white leaves it unchanged, the grey
-- silhouette darkens it. (The engine ignores ONE_MINUS_SRC_COLOR here.)
-- Only the third argument reliably identifies the 3D skybox pass.
hook.Add('PostDrawOpaqueRenderables','rf_geomod_shadows',function(depth,_,sky3d)
    if depth or sky3d then return end
    if enabled:GetBool() and (not rShadows or rShadows:GetBool()) and not GetGlobal2Bool('RFGeoModShadowDisabled',false) then
        drawWallShadows()
    end
    if #active==0 then return end
    render.SetMaterial(projected)
    render.OverrideDepthEnable(true,false)
    local debug=debugView:GetBool()
    if not debug then render.OverrideBlend(true,BLEND_DST_COLOR,BLEND_ZERO,BLENDFUNC_ADD) end
    for _,a in ipairs(active) do if a.entry.mesh then a.entry.mesh:Draw() end end
    render.OverrideBlend(false)
    render.OverrideDepthEnable(false)
end)

hook.Add('EntityRemoved','rf_geomod_shadows',function(ent) release(ent) pool[ent]=nil end)
-- Why an entity does or does not cast this frame (QA and console debugging).
local function explain(ent)
    local ok,reason=isCaster(ent,MainEyePos())
    local d=diagnostics[ent] or {}
    return {pool=pool[ent]==true,caster=ok==true,reason=not ok and reason or nil,hits=d.hits,
        shade=d.shade,vertices=d.vertices,gap=d.gap,active=casters[ent]~=nil}
end
G.Shadows={Casters=function() return casters end,Active=function() return active end,Stats=stats,Explain=explain}
