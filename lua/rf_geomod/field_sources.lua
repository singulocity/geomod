-- Immutable authored-brush import. All field geometry, cuts and UV axes use
-- world space; brush entity origins do not become independent cut frames.
local G,V=RFGeoMod,RFGeoMod.Field
local S={}
local axes={'x','y','z'}
function S.Materials(descriptors,cut)
    local names={false,cut}
    local ids={}
    for _,desc in ipairs(descriptors) do
        local src=assert(G.ReadBrushModel(desc.model,desc.config.cut_material))
        for _,name in ipairs(src.materials) do
            if not ids[name] then
                local id=not names[1] and 0 or #names
                names[id+1]=name ids[name]=id
            end
        end
    end
    return names
end
function S.Import(desc,palette)
    local source,err=G.ReadBrushModel(desc.model,desc.config.cut_material)
    assert(source,err)
    local ids={}
    local pos,ang=Vector(unpack(desc.pos)),Angle(unpack(desc.ang))
    for i,name in ipairs(palette) do if i~=2 then ids[name]=i-1 end end
    local result={}
    for _,piece in ipairs(source.pieces) do
        local faces={}
        for _,face in ipairs(piece.faces) do
            local points={}
            for _,p in ipairs(face.points) do points[#points+1]=LocalToWorld(p,angle_zero,pos,ang) end
            local uv
            if face.uv then
                local a=face.uv
                local u=LocalToWorld(a.u,angle_zero,vector_origin,ang)
                local v=LocalToWorld(a.v,angle_zero,vector_origin,ang)
                uv={u=u,v=v,uo=a.uo-u:Dot(pos),vo=a.vo-v:Dot(pos),width=a.width,height=a.height}
            end
            faces[#faces+1]={points=points,uv=uv,mat=assert(ids[source.materials[face.mat+1]]),nodraw=face.nodraw}
        end
        local prepared=assert(G.Prepare(faces),'Invalid transformed field source')
        for i,face in ipairs(prepared.faces) do
            face.source_meta={model=desc.model,pos=pos,ang=ang,normal=piece.faces[i].normal}
        end
        result[#result+1]=prepared
    end
    return result
end
function S.Build(data)
    local imported={}
    for i,desc in ipairs(data.sources) do imported[i]=S.Import(desc,data.materials) end
    local pieces={}
    for _,member in ipairs(data.members) do pieces[#pieces+1]=assert(imported[member.s][member.p]) end
    local groups=G.FieldGroups.Build(pieces,32,{axis_adaptive=true})
    assert(#groups==1,'Static source membership no longer forms one group')
    return groups[1]
end
function S.Partitions(brushes)
    local buckets,ordered={},{}
    for _,brush in ipairs(brushes) do
        local c=brush.WallKeyValues or {}
        local config={hardness=G.ClampHardness(c.hardness),cut_material=c.cut_material or 'concrete/concretewall036a',
            cut_repeat=tonumber(c.cut_repeat) or 128,disable_physgun=c.disable_physgun,disable_tools=c.disable_tools}
        local key=config.cut_material..':'..config.hardness..':'..config.cut_repeat
        if not buckets[key] then buckets[key]={sources={},brushes={}} ordered[#ordered+1]=buckets[key] end
        local bucket=buckets[key]
        local p,a=brush:GetPos(),brush:GetAngles()
        bucket.sources[#bucket.sources+1]={model=brush:GetModel(),pos={p.x,p.y,p.z},ang={a.p,a.y,a.r},config=config}
        bucket.brushes[#bucket.brushes+1]=brush
    end
    local result={}
    for _,bucket in ipairs(ordered) do
        local palette=S.Materials(bucket.sources,bucket.sources[1].config.cut_material)
        local flat,owners={},{}
        for s,desc in ipairs(bucket.sources) do for p,piece in ipairs(S.Import(desc,palette)) do
            flat[#flat+1]=piece owners[#owners+1]={s=s,p=p}
        end end
        for _,volume in ipairs(G.FieldGroups.Build(flat,32,{axis_adaptive=true})) do
            local data={sources={},members={},materials=palette,config=bucket.sources[1].config}
            local sourceIDs={}
            local sourceBrushes={}
            local brushesForGroup={}
            for _,index in ipairs(volume.source_indices) do
                local owner=owners[index]
                if not sourceIDs[owner.s] then
                    data.sources[#data.sources+1]=bucket.sources[owner.s] sourceIDs[owner.s]=#data.sources
                    sourceBrushes[#sourceBrushes+1]=bucket.brushes[owner.s]
                end
                data.members[#data.members+1]={s=sourceIDs[owner.s],p=owner.p}
                brushesForGroup[bucket.brushes[owner.s]]=true
            end
            result[#result+1]={data=data,volume=volume,brushes=brushesForGroup,sourceBrushes=sourceBrushes}
        end
    end
    return result
end
G.FieldSources=S
return S
