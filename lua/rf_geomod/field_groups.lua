-- RF-094 static contact groups. Inputs are already in world space.
-- Grouping happens once on source solids, never on accumulated cut triangles.
local V,G=RFGeoMod.Field,RFGeoMod
local M={}
-- Exposed polygon boundary of a contact group, computed once from authored inputs.
local function exteriorFaces(source)
    local collision={}
    for _,piece in ipairs(source) do
        local faces={}
        for _,face in ipairs(piece.faces) do
            faces[#faces+1]={points=face.points,normal=face.normal,d=face.d,mat=face.mat,uv=face.uv,origin_face=face}
        end
        collision[#collision+1]={faces=faces,planes=piece.planes,low=piece.low,high=piece.high}
    end
    return (G.ExposedFaces(collision))
end
function M.Build(pieces,spacing,options)
    local groups={}
    for _,island in ipairs(G.Islands(pieces)) do
        local source={}
        for _,index in ipairs(island.indices) do source[#source+1]=pieces[index] end
        local low,high=G.Bounds(source)
        -- The per-axis cell size only positions the chunk lattice. It is kept
        -- as authored so existing chunk keys and boundaries do not move.
        local selected=spacing or 32
        local grid=Vector(selected,selected,selected)
        local minimum=math.huge
        for _,piece in ipairs(source) do for _,face in ipairs(piece.faces) do
            local opposite=math.huge
            for _,p in ipairs(piece.vertices) do opposite=math.min(opposite,face.normal:Dot(p)) end
            minimum=math.min(minimum,face.d-opposite)
            if options and options.axis_adaptive then
                local width=face.d-opposite
                for _,axis in ipairs({'x','y','z'}) do
                    local projection=math.abs(face.normal[axis])
                    while projection*grid[axis]>=width-1e-5 and grid[axis]>4 do grid[axis]=grid[axis]/2 end
                    assert(projection*grid[axis]<width-1e-5,'Source needs sampling finer than the supported minimum')
                end
            end
        end end
        if options and options.axis_adaptive then selected=grid
        elseif not options or options.adaptive~=false then
            while minimum<=selected+1e-5 and selected>4 do selected=selected/2 end
            assert(minimum>selected+1e-5,'Source feature needs sampling finer than the supported 4-unit minimum')
        end
        -- One spacing per contact group keeps touching brushes on the same
        -- lattice. Disconnected bulk groups retain their coarser setting.
        local volume=V.New(source,low,high,selected,type(selected)=='number' and 128/selected or nil)
        volume.exterior=exteriorFaces(source)
        volume.source_indices=island.indices
        if not options or options.sparse~=false then
            local byKey={}
            for _,piece in ipairs(source) do
                local lowChunk,highChunk={},{}
                for i,axis in ipairs({'x','y','z'}) do
                    lowChunk[i]=math.floor(math.max(0,math.floor((piece.low[axis]-volume.origin[axis])/volume.spacing[axis])-2)/volume.chunkCells[i])
                    highChunk[i]=math.floor(math.min(volume.size[i]-1,math.ceil((piece.high[axis]-volume.origin[axis])/volume.spacing[axis])+2)/volume.chunkCells[i])
                end
                for x=lowChunk[1],highChunk[1] do for y=lowChunk[2],highChunk[2] do for z=lowChunk[3],highChunk[3] do
                    local key=volume:ChunkKey(x,y,z) byKey[key]={x=x,y=y,z=z,key=key}
                end end end
            end
            volume.sourceChunkList={}
            for _,chunk in pairs(byKey) do volume.sourceChunkList[#volume.sourceChunkList+1]=chunk end
            table.sort(volume.sourceChunkList,function(a,b) if a.x~=b.x then return a.x<b.x elseif a.y~=b.y then return a.y<b.y else return a.z<b.z end end)
        end
        groups[#groups+1]=volume
    end
    return groups
end
RFGeoMod.FieldGroups=M
return M
