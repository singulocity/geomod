-- Exposed polygon boundaries of convex brush unions and static GeoMod cuts.
RFGeoMod=RFGeoMod or {}
local EPS=0.001

local function clipPolygon(points,n,d,inside)
    local out={}
    for i,a in ipairs(points) do
        local b=points[i%#points+1]
        local da,db=n:Dot(a)-d,n:Dot(b)-d
        if (inside and da<=EPS) or (not inside and da>=-EPS) then out[#out+1]=a end
        if (da < -EPS and db > EPS) or (da > EPS and db < -EPS) then
            out[#out+1]=a+(b-a)*(da/(da-db))
        end
    end
    return out
end

local function area(points)
    local sum=Vector()
    for i=2,#points-1 do sum=sum+(points[i]-points[1]):Cross(points[i+1]-points[1]) end
    return sum:Length()*.5
end

-- Each result lies outside at least one plane. Discard the remaining polygon
-- inside all planes. An untouched polygon keeps its original vertex order.
local function subtract(points,planes,normal)
    local interior=points
    for _,plane in ipairs(planes) do
        if normal and plane.normal:Dot(normal)<-.999999 then
            local coplanar=true
            for _,point in ipairs(points) do
                if math.abs(plane.normal:Dot(point)-plane.d)>EPS then coplanar=false break end
            end
            if coplanar then return {points} end
        end
        interior=clipPolygon(interior,plane.normal,plane.d,true)
        if #interior<3 then return {points} end
    end
    if area(interior)<.00001 then return {points} end
    local fragments={}
    for _,plane in ipairs(planes) do
        local outside=false
        for _,point in ipairs(points) do
            if plane.normal:Dot(point)-plane.d>EPS then outside=true break end
        end
        if outside then
            fragments[#fragments+1]=clipPolygon(points,plane.normal,plane.d,false)
            points=clipPolygon(points,plane.normal,plane.d,true)
            if #points<3 then break end
        end
    end
    return fragments,interior
end

local function polygonBounds(points)
    local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    for _,p in ipairs(points) do
        low.x=math.min(low.x,p.x) low.y=math.min(low.y,p.y) low.z=math.min(low.z,p.z)
        high.x=math.max(high.x,p.x) high.y=math.max(high.y,p.y) high.z=math.max(high.z,p.z)
    end
    return low,high
end

local function overlaps(low,high,other)
    return low.x<=other.high.x+EPS and high.x>=other.low.x-EPS
        and low.y<=other.high.y+EPS and high.y>=other.low.y-EPS
        and low.z<=other.high.z+EPS and high.z>=other.low.z-EPS
end

local function subtractFrom(polygons,solid,checkpoint)
    local result={}
    for _,polygon in ipairs(polygons) do
        local low,high=polygonBounds(polygon)
        local fragments=overlaps(low,high,solid) and subtract(polygon,solid.planes) or {polygon}
        for _,fragment in ipairs(fragments) do result[#result+1]=fragment end
        checkpoint()
    end
    return result
end

local function cutter(op)
    local planes=RFGeoMod.CutterPlanes(op.radius,op.seed,op.normal,op.bore,op.ram)
    local extent=op.ram and RFGeoMod.RamCutExtent(op.ram) or op.radius*3
    local bounds=Vector(extent,extent,extent)
    local cuts={planes=planes,faces={},center=op.center,low=op.center-bounds,high=op.center+bounds}
    for _,p in ipairs(planes) do p.d=p.d+p.normal:Dot(op.center) end
    for _,p in ipairs(planes) do
        local n=p.normal
        local axis=math.abs(n.z)>.9 and Vector(1,0,0) or Vector(0,0,1)
        local u=n:Cross(axis):GetNormalized()*extent
        local v=n:Cross(u)
        local center=op.center+n*(p.d-n:Dot(op.center))
        -- The cutter's exterior faces point into the removed volume when
        -- they become cavity faces in the surviving solid.
        local polygon={center-u-v,center-u+v,center+u+v,center+u-v}
        for _,plane in ipairs(planes) do
            if plane~=p then polygon=clipPolygon(polygon,plane.normal,plane.d,true) end
            if #polygon<3 then break end
        end
        if #polygon>=3 then cuts.faces[#cuts.faces+1]={points=polygon,plane=p} end
    end
    return cuts
end

local function ownerKey(volume,p)
    if not volume.spacing then return 'local' end
    local relative=p-volume.origin
    return volume:ChunkKey(
        math.max(0,math.floor(relative.x/(volume.chunkCells[1]*volume.spacing.x))),
        math.max(0,math.floor(relative.y/(volume.chunkCells[2]*volume.spacing.y))),
        math.max(0,math.floor(relative.z/(volume.chunkCells[3]*volume.spacing.z))))
end

local function addShape(state,key,points,normal,face)
    local low,high=polygonBounds(points)
    state.shapes[#state.shapes+1]={key=key,points=points,normal=normal,face=face,low=low,high=high}
    state.dirty[key]=true
end

local function signedVolume(points,origin)
    if #points<3 then return 0 end
    local volume=0
    local a=points[1]-origin
    for i=2,#points-1 do
        volume=volume+a:Dot((points[i]-origin):Cross(points[i+1]-origin))
    end
    return volume/6
end

local function cutBoundary(volume,state,cut,checkpoint,removedFaces)
    local previous=state.shapes
    state.shapes={}
    local removed=0
    local changed=0
    for _,shape in ipairs(previous) do
        local fragments,interior
        if overlaps(shape.low,shape.high,cut) then
            fragments,interior=subtract(shape.points,cut.planes,shape.normal)
        end
        if not fragments or fragments[1]==shape.points then
            state.shapes[#state.shapes+1]=shape
        else
            state.dirty[shape.key]=true
            changed=changed+1
            if removedFaces then removedFaces[#removedFaces+1]={points=interior,normal=shape.normal} end
            removed=removed+signedVolume(shape.points,cut.center)
            for _,points in ipairs(fragments) do
                removed=removed-signedVolume(points,cut.center)
                addShape(state,shape.key,points,shape.normal,shape.face)
            end
        end
        checkpoint()
    end
    for _,face in ipairs(cut.faces) do
        local low,high=polygonBounds(face.points)
        local pieces=volume.boundaryPieces or volume.pieces
        for i,piece in ipairs(pieces) do
            if overlaps(low,high,piece) then
                local polygon=face.points
                for _,plane in ipairs(piece.planes) do
                    -- The surviving side of a cavity face must be in this
                    -- brush. This also covers cuts along a shared brush plane.
                    if plane.normal:Dot(face.plane.normal)>.999999
                        and math.abs(plane.normal:Dot(face.points[1])-plane.d)<EPS then
                        polygon={}
                        break
                    end
                    polygon=clipPolygon(polygon,plane.normal,plane.d,true)
                    if #polygon<3 then break end
                end
                if #polygon>=3 then
                    local fragments={polygon}
                    for j=1,i-1 do
                        fragments=subtractFrom(fragments,pieces[j],checkpoint)
                        if #fragments==0 then break end
                    end
                    for _,earlier in ipairs(state.cuts) do
                        fragments=subtractFrom(fragments,earlier,checkpoint)
                        if #fragments==0 then break end
                    end
                    local key=ownerKey(volume,piece.low)
                    local normal=-face.plane.normal
                    for _,points in ipairs(fragments) do
                        removed=removed-signedVolume(points,cut.center)
                        changed=changed+1
                        if removedFaces then removedFaces[#removedFaces+1]={points=points,normal=face.plane.normal} end
                        addShape(state,key,points,normal)
                    end
                end
            end
            checkpoint()
        end
    end
    return removed,changed
end

local function boundaryState(volume,checkpoint)
    local state=volume.authoredBoundary
    if not state then
        state={shapes={},cuts={},triangles={},dirty={}}
        volume.authoredBoundary=state
        for _,polygon in ipairs(volume.boundaryExterior or volume.exterior) do
            local low=polygonBounds(polygon.points)
            addShape(state,ownerKey(volume,low),polygon.points,polygon.normal,polygon.origin_face)
            checkpoint()
        end
    end
    return state
end

function RFGeoMod.NewLocalBoundary(pieces,checkpoint)
    return {pieces=pieces,exterior=RFGeoMod.ExposedFaces(pieces,checkpoint),queryCuts={},revision=0}
end

function RFGeoMod.AuthoredPolygons(volume,checkpoint)
    return boundaryState(volume,checkpoint).shapes
end

-- Rebase the surviving shell after an entire connected island leaves.
-- Keep original face references for lightmaps and add the removed convex
-- solids to the same continuous query used by weapon traces.
function RFGeoMod.DropAuthoredIsland(volume,remaining,detached,checkpoint)
    for _,piece in ipairs(detached) do
        local query={}
        for _,plane in ipairs(piece.planes) do
            local n=plane.normal
            query[#query+1]={n.x,n.y,n.z,plane.d,n}
        end
        volume.queryCuts[#volume.queryCuts+1]=query
    end
    local physical={}
    for _,piece in ipairs(remaining) do
        local faces={}
        for _,face in ipairs(piece.faces) do
            faces[#faces+1]={points=face.points,normal=face.normal,d=face.d,mat=face.mat,
                uv=face.uv,origin_face=face.origin_face or face}
        end
        physical[#physical+1]={faces=faces,planes=piece.planes,low=piece.low,high=piece.high}
    end
    volume.boundaryPieces=remaining
    volume.boundaryExterior=RFGeoMod.ExposedFaces(physical,checkpoint)
    volume.authoredBoundary=nil
    volume.revision=volume.revision+1
end

-- Accept a static cut from the same boundary that will paint and collide.
-- A replay applies the server's accepted history in its original order.
function RFGeoMod.CutAuthoredBoundary(volume,op,checkpoint,replay,removedFaces)
    local state=boundaryState(volume,checkpoint)
    local shapes,dirty=state.shapes,state.dirty
    state.dirty={}
    local cut=cutter(op)
    local removed,changed=cutBoundary(volume,state,cut,checkpoint,removedFaces)
    if not replay and removed<=EPS then
        state.shapes,state.dirty=shapes,dirty
        return 0,0
    end
    for key in pairs(dirty) do state.dirty[key]=true end
    cut.faces=nil
    state.cuts[#state.cuts+1]=cut
    local query={}
    for _,plane in ipairs(cut.planes) do
        local n=plane.normal
        query[#query+1]={n.x,n.y,n.z,plane.d,n}
    end
    volume.queryCuts[#volume.queryCuts+1]=query
    volume.revision=volume.revision+1
    return math.max(0,removed),changed
end

-- Reuse the original polygons and surviving fragments across cuts. A face's
-- chunk ownership remains stable even when it spans the chunk's grid bounds.
function RFGeoMod.AuthoredBoundary(volume,checkpoint)
    local state=boundaryState(volume,checkpoint)
    for key in pairs(state.dirty) do state.triangles[key]={} end
    for _,shape in ipairs(state.shapes) do
        if state.dirty[shape.key] then
            local triangles=state.triangles[shape.key]
            local points=shape.points
            local face=shape.face
            for i=2,#points-1 do
                local a,b,c=points[1],points[i],points[i+1]
                if (b-a):Cross(c-a):LengthSqr()>1e-10 then
                    triangles[#triangles+1]={a,b,c,normal=shape.normal,mat=face and face.mat or 1,face=face}
                end
            end
        end
        checkpoint()
    end
    state.dirty={}
    return state.triangles
end

function RFGeoMod.ExposedFaces(pieces,checkpoint)
    checkpoint=checkpoint or function() end
    local result,stats={},{input_faces=0,output_faces=0,buried_faces=0,input_area=0,output_area=0}
    for owner,piece in ipairs(pieces) do for _,face in ipairs(piece.faces) do
        if not face.nodraw then
            stats.input_faces=stats.input_faces+1 stats.input_area=stats.input_area+area(face.points)
            local fragments={face.points}
            local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
            for _,p in ipairs(face.points) do
                low.x=math.min(low.x,p.x) low.y=math.min(low.y,p.y) low.z=math.min(low.z,p.z)
                high.x=math.max(high.x,p.x) high.y=math.max(high.y,p.y) high.z=math.max(high.z,p.z)
            end
            for other,neighbor in ipairs(pieces) do
                checkpoint()
                if other~=owner and low.x<=neighbor.high.x+EPS and high.x>=neighbor.low.x-EPS and
                    low.y<=neighbor.high.y+EPS and high.y>=neighbor.low.y-EPS and
                    low.z<=neighbor.high.z+EPS and high.z>=neighbor.low.z-EPS then
                    local overlaps=true
                    for _,plane in ipairs(neighbor.planes) do
                        local minimum,maximum=math.huge,-math.huge
                        for _,p in ipairs(face.points) do
                            local distance=plane.normal:Dot(p)-plane.d
                            minimum=math.min(minimum,distance) maximum=math.max(maximum,distance)
                        end
                        -- Preserve same-facing exterior boundaries once, using
                        -- piece order to resolve overlapping source brushes.
                        -- Opposite-facing coplanar seams are always buried.
                        if minimum>EPS or (math.abs(minimum)<=EPS and math.abs(maximum)<=EPS and
                            plane.normal:Dot(face.normal)>0 and other>owner) then overlaps=false break end
                    end
                    if overlaps then
                        local nextFragments={}
                        for _,polygon in ipairs(fragments) do
                            local remaining=polygon
                            for _,plane in ipairs(neighbor.planes) do
                                if #remaining<3 then break end
                                local minimum,maximum=math.huge,-math.huge
                                for _,p in ipairs(remaining) do
                                    local distance=plane.normal:Dot(p)-plane.d
                                    minimum=math.min(minimum,distance) maximum=math.max(maximum,distance)
                                end
                                if minimum>EPS then nextFragments[#nextFragments+1]=remaining remaining={} break end
                                if maximum>EPS then
                                    local outside=clipPolygon(remaining,plane.normal,plane.d,false)
                                    if #outside>=3 and area(outside)>0.00001 then nextFragments[#nextFragments+1]=outside end
                                    remaining=clipPolygon(remaining,plane.normal,plane.d,true)
                                end
                            end
                            -- The remainder is covered by the neighboring solid.
                        end
                        fragments=nextFragments
                        if #fragments==0 then break end
                    end
                end
            end
            if #fragments==0 then stats.buried_faces=stats.buried_faces+1 end
            for _,polygon in ipairs(fragments) do
                if #polygon>=3 and area(polygon)>0.00001 then
                    result[#result+1]={points=polygon,normal=face.normal,d=face.d,mat=face.mat,uv=face.uv,origin_face=face.origin_face or face}
                    stats.output_area=stats.output_area+area(polygon)
                end
            end
        end
    end end
    stats.output_faces=#result
    return result,stats
end
