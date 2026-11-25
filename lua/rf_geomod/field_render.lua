-- World-space chunk meshes. CPU preparation is resumable; GPU publication is atomic.
local G,V=RFGeoMod,RFGeoMod.Field
local R={}
G.FieldRender=R
local materials={}
local function material(path,kind)
    local key=path..':'..kind
    if materials[key] then return materials[key] end
    local source=Material(path)
    local texture=source:GetTexture('$basetexture')
    local shader=kind=='baked' and 'LightmappedGeneric' or kind=='projected' and 'VertexLitGeneric' or 'UnlitGeneric'
    local tint=kind=='baked' and game.GetMap()=='rf_dm01_lobby' and '[0.9 0.9 0.9]' or '[1 1 1]'
    materials[key]=CreateMaterial('rf_geomod_field_'..util.CRC(key),shader,{
        ['$basetexture']=texture and texture:GetName() or 'dev/dev_measurewall01a',
        ['$vertexcolor']=kind=='baked' and '0' or '1',['$color2']=tint,['$nocull']='0'})
    return materials[key]
end
local function gpu(vertices,mat,baked,white)
    local result=Mesh(mat)
    mesh.Begin(result,MATERIAL_TRIANGLES,#vertices/3)
    for _,v in ipairs(vertices) do
        mesh.Position(v.pos) mesh.Normal(v.normal) mesh.TexCoord(0,v.u,v.v)
        if baked then mesh.TexCoord(1,v.u1,v.v1) end
        local c=white and color_white or v.color or color_white mesh.Color(c.r,c.g,c.b,255) mesh.AdvanceVertex()
    end
    mesh.End()
    return result
end
local function channel(n) return math.Round(math.Clamp(n,0,1)^(1/2.2)*255) end
function R.Prepare(wall,ent,triangles,checkpoint,cpuOnly)
    local result={batches={},owned={},vertices={},scorches={}}
    ent.FieldPreparingBundle=result
    local groups,order={},{}
    local light={}
    -- Authored pieces are immutable for the wall's lifetime; share this scan
    -- across chunk rebuilds instead of repeating it for every chunk.
    local neighbors=wall.FieldLightmapNeighbors or {}
    wall.FieldLightmapNeighbors=neighbors
    local function lightmapNeighbors(face)
        if neighbors[face] then return neighbors[face] end
        local result,seen={},{}
        -- One field triangle can span adjoining authored brushes. Its selected
        -- source face owns the UVs, but neighboring brushes own some lightmaps.
        for _,piece in ipairs(wall.FieldVolume.pieces) do for _,other in ipairs(piece.faces) do
            local meta=other.source_meta
            if meta and meta.model~=face.source_meta.model and not seen[meta.model] and other.mat==face.mat and
                other.normal:Dot(face.normal)>.9999 and math.abs(other.d-face.d)<.03 then
                seen[meta.model]=true result[#result+1]=meta
            end
        end end
        neighbors[face]=result return result
    end
    local function output(t,points,meta,lm,atlas)
        local id=t.mat+1
        local kind=lm and 'baked' or 'sampled'
        local key=id..':'..kind..':'..(meta and meta.model or '')
        local group=groups[key]
        if not group then
            group={vertices={},id=id,model=meta and meta.model or '',material=material(wall.WallMaterialNames[id],kind),
                projectedMaterial=material(wall.WallMaterialNames[id],'projected'),atlas=atlas,baked=lm~=nil}
            groups[key]=group order[#order+1]=group
        end
        result.vertices[id]=result.vertices[id] or {}
        local function vertex(p)
            local world=meta and LocalToWorld(p,angle_zero,meta.pos,meta.ang) or p
            local u,v=V.UV(t,world,wall.CutRepeat)
            local color=color_white
            if not lm then
                local k=math.Round(world.x/8)..':'..math.Round(world.y/8)..':'..math.Round(world.z/8)..':'..math.Round(t.normal.x*8)..':'..math.Round(t.normal.y*8)..':'..math.Round(t.normal.z*8)
                color=light[k]
                if not color then
                    local sample=world+t.normal*2
                    local n=render.ComputeLighting(sample,t.normal)-render.ComputeDynamicLighting(sample,t.normal)
                    color=Color(channel(n.x),channel(n.y),channel(n.z)) light[k]=color
                end
            end
            local entry={pos=world,normal=t.normal,u=u,v=v,color=color}
            if lm then
                entry.u1=(lm.x+p:Dot(lm.u)+lm.uo-lm.smin+.5)/atlas.width
                entry.v1=(lm.y+p:Dot(lm.v)+lm.vo-lm.tmin+.5)/atlas.height
            end
            group.vertices[#group.vertices+1]=entry
            result.vertices[id][#result.vertices[id]+1]=entry
        end
        for i=2,#points-1 do vertex(points[1]) vertex(points[i+1]) vertex(points[i]) end
    end
    local scorchGroups={}
    for ti,t in ipairs(triangles) do
        wall.FieldProgress.triangle=ti wall.FieldProgress.total=#triangles
        local face=t.face
        if not face or not face.nodraw then
            local meta=face and face.source_meta
            local atlas=meta and G.ReadLightmaps(meta.model)
            if meta and atlas and face.uv then
                local points={}
                for i=1,3 do points[i]=WorldToLocal(t[i],angle_zero,meta.pos,meta.ang) end
                local proxy={points=points,normal=meta.normal,mat=t.mat,uv=face.uv}
                for _,fragment in ipairs(G.LightmapFragments(proxy,atlas)) do
                    if fragment.lightmap then
                        output(t,fragment.points,meta,fragment.lightmap,atlas)
                    else
                        local pending={}
                        local world={}
                        for _,p in ipairs(fragment.points) do world[#world+1]=LocalToWorld(p,angle_zero,meta.pos,meta.ang) end
                        pending[1]=world
                        for _,neighbor in ipairs(lightmapNeighbors(face)) do
                            if #pending==0 then break end
                            local adjacent=G.ReadLightmaps(neighbor.model)
                            if adjacent then
                                local remaining={}
                                for _,polygon in ipairs(pending) do
                                    local localPoints={}
                                    for _,p in ipairs(polygon) do localPoints[#localPoints+1]=WorldToLocal(p,angle_zero,neighbor.pos,neighbor.ang) end
                                    local patch={points=localPoints,normal=neighbor.normal,mat=t.mat,uv=face.uv}
                                    for _,part in ipairs(G.LightmapFragments(patch,adjacent)) do
                                        if part.lightmap then output(t,part.points,neighbor,part.lightmap,adjacent)
                                        else
                                            local uncovered={}
                                            for _,p in ipairs(part.points) do uncovered[#uncovered+1]=LocalToWorld(p,angle_zero,neighbor.pos,neighbor.ang) end
                                            remaining[#remaining+1]=uncovered
                                        end
                                    end
                                end
                                pending=remaining
                            end
                        end
                        for _,polygon in ipairs(pending) do output(t,polygon) end
                    end
                end
            else output(t,{t[1],t[2],t[3]}) end
            if t.mat~=1 then
                local n=t.normal local d=n:Dot(t[1])
                local passes,basis=G.ScorchPasses(wall.Cuts,n,d,face)
                if basis then
                    local key=string.format('%.3f:%.3f:%.3f:%.2f',n.x,n.y,n.z,d)
                    if face then
                        local sourceNormal=face.normal
                        key=key..string.format(':%.3f:%.3f:%.3f:%.2f',sourceNormal.x,sourceNormal.y,sourceNormal.z,face.d)
                    end
                    local s=scorchGroups[key]
                    if not s then s={vertices={},passes=passes,basis=basis} scorchGroups[key]=s end
                    -- Keep the scorch on the wall perimeter. The decal
                    -- material supplies depth bias without exposing a rim.
                    for _,i in ipairs({1,3,2}) do local p=t[i]
                        s.vertices[#s.vertices+1]={pos=p,normal=n,u=p:Dot(basis.u),v=p:Dot(basis.v),color=color_white}
                    end
                end
            end
        end
        checkpoint()
    end
    for _,group in ipairs(order) do
        if #group.vertices>0 then
            if not cpuOnly then
                group.mesh=gpu(group.vertices,group.material,group.baked) result.owned[#result.owned+1]=group.mesh
                checkpoint()
                group.projectedMesh=gpu(group.vertices,group.projectedMaterial,false,true) result.owned[#result.owned+1]=group.projectedMesh
            end
            result.batches[#result.batches+1]=group checkpoint()
        end
    end
    for _,s in pairs(scorchGroups) do
        s.mesh=gpu(s.vertices,G.GetScorchMaterial(),false) result.owned[#result.owned+1]=s.mesh
        result.scorches[#result.scorches+1]=s checkpoint()
    end
    return result
end
function R.Restore(wall,ent,batches,checkpoint)
    local result={batches={},owned={},vertices={},scorches={}}
    ent.FieldPreparingBundle=result
    for _,b in ipairs(batches) do
        b.material=material(wall.WallMaterialNames[b.id],b.baked and 'baked' or 'sampled')
        b.projectedMaterial=material(wall.WallMaterialNames[b.id],'projected')
        b.atlas=b.baked and assert(G.ReadLightmaps(b.model),'Cached lightmap unavailable') or nil
        result.vertices[b.id]=result.vertices[b.id] or {}
        for i,v in ipairs(b.vertices) do
            result.vertices[b.id][#result.vertices[b.id]+1]=v
            if i%128==0 then checkpoint() end
        end
        b.mesh=gpu(b.vertices,b.material,b.baked) result.owned[#result.owned+1]=b.mesh checkpoint()
        b.projectedMesh=gpu(b.vertices,b.projectedMaterial,false,true) result.owned[#result.owned+1]=b.projectedMesh checkpoint()
        result.batches[#result.batches+1]=b
    end
    return result
end
function R.Clear(ent)
    G.FieldRenderRevision=(G.FieldRenderRevision or 0)+1
    for _,m in ipairs(ent.FieldRenderBundle and ent.FieldRenderBundle.owned or {}) do m:Destroy() end
    if ent.FieldPreparingBundle~=ent.FieldRenderBundle then
        for _,m in ipairs(ent.FieldPreparingBundle and ent.FieldPreparingBundle.owned or {}) do m:Destroy() end
    end
    ent.FieldRenderBundle=nil ent.FieldPreparingBundle=nil ent.FieldVertices=nil
end
function R.Commit(wall,ent,bundle)
    G.FieldRenderRevision=(G.FieldRenderRevision or 0)+1
    ent.FieldPreparingBundle=nil
    R.Clear(ent) ent.FieldRenderBundle=bundle ent.FieldVertices=bundle.vertices
end
function R.Draw(ent)
    local wall=ent.GeoModProxy
    local state=IsValid(wall) and wall.FieldClientState
    -- The intact native proxy stays visible until the group is ready. Drawing
    -- published chunks before that handoff puts two surfaces at the same depth.
    if not state or not state.initialReady then return end
    local bundle=ent.FieldRenderBundle if not bundle then return end
    ent.FieldVisibleFrame=FrameNumber()
    for _,b in ipairs(bundle.batches) do
        render.SetMaterial(b.material)
        if b.baked then render.SetLightmapTexture(b.atlas.texture) end
        b.mesh:Draw()
    end
    G.DrawScorches(wall,bundle.scorches)
end
-- One projected-light pass for the visible field, rather than restarting the
-- engine flashlight pass separately for every material of every chunk.
hook.Add('PostDrawOpaqueRenderables','rf_geomod_field_flashlights',function(depth,_,sky3d)
    if depth or sky3d then return end
    render.RenderFlashlights(function()
        local frame=FrameNumber()
        for wall in pairs(G.Static and G.Static.states or {}) do
            for _,ent in pairs(IsValid(wall) and wall.FieldChunks or {}) do
                if IsValid(ent) and ent.FieldVisibleFrame==frame and ent.FieldRenderBundle then
                    for _,b in ipairs(ent.FieldRenderBundle.batches) do
                        render.SetMaterial(b.projectedMaterial) b.projectedMesh:Draw()
                    end
                end
            end
        end
    end)
end)
