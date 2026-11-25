-- Authored brush primitives, contact grouping and movable-wall convex CSG.
-- Static map edits use field.lua and triangle-mesh physics instead.
RFGeoMod = RFGeoMod or {}
local G = RFGeoMod
local EPS = 0.001
G.MaxCuts, G.MaxPieces = 255, 512

if SERVER then
    local radiusScale=CreateConVar('rf_geomod_radius_scale','0.65',FCVAR_ARCHIVE,
        'GeoMod crater radius multiplier; 1 restores the original size.',0.25,1)
    function G.BlastRadius(damage)
        return 80*radiusScale:GetFloat()*math.Clamp(math.sqrt((damage or 100)/100),0.7,1.25)
    end
end

local function unique(points)
    local result = {}
    for _, p in ipairs(points) do
        local found = false
        for _, q in ipairs(result) do
            if p:DistToSqr(q) < 0.0001 then found = true break end
        end
        if not found then result[#result+1] = p end
    end
    return result
end

local function clean(points)
    local result = unique(points)
    local again = true
    while again and #result > 3 do
        again = false
        for i, p in ipairs(result) do
            local a, b = result[(i-2)%#result+1], result[i%#result+1]
            local ab, bc = p-a, b-p
            if ab:LengthSqr() < 0.0001 or bc:LengthSqr() < 0.0001 or
                ab:Cross(bc):LengthSqr() < 0.000001*ab:LengthSqr()*bc:LengthSqr() then
                table.remove(result,i) again = true break
            end
        end
    end
    return result
end

function G.Prepare(faces)
    local piece = {faces={}, planes={}, vertices={}, low=Vector(math.huge,math.huge,math.huge),
                   high=Vector(-math.huge,-math.huge,-math.huge)}
    local volume, all = 0, {}
    for _, face in ipairs(faces) do
        local p = clean(face.points)
        if #p >= 3 then
            local normal = (p[2]-p[1]):Cross(p[3]-p[1])
            if normal:LengthSqr() > 0.00001 then
                normal:Normalize()
                local d = normal:Dot(p[1])
                piece.faces[#piece.faces+1] = {points=p, mat=face.mat, normal=normal, d=d,uv=face.uv,nodraw=face.nodraw,
                    origin_face=face.origin_face}
                piece.planes[#piece.planes+1] = {normal=normal,d=d}
                for _, v in ipairs(p) do all[#all+1] = v end
                for i=2,#p-1 do volume = volume+p[1]:Dot(p[i]:Cross(p[i+1]))/6 end
            end
        end
    end
    piece.vertices = unique(all)
    if #piece.vertices < 4 or math.abs(volume) < 0.05 then return nil end
    piece.volume = math.abs(volume)
    for _, p in ipairs(piece.vertices) do
        piece.low.x = math.min(piece.low.x,p.x) piece.high.x = math.max(piece.high.x,p.x)
        piece.low.y = math.min(piece.low.y,p.y) piece.high.y = math.max(piece.high.y,p.y)
        piece.low.z = math.min(piece.low.z,p.z) piece.high.z = math.max(piece.high.z,p.z)
    end
    return piece
end

function G.Box(low,high)
    local p = {}
    for i=0,7 do
        p[i+1] = Vector(bit.band(i,1)~=0 and high.x or low.x,
                        bit.band(i,2)~=0 and high.y or low.y,
                        bit.band(i,4)~=0 and high.z or low.z)
    end
    local indices = {{1,5,7,3},{2,4,8,6},{1,2,6,5},{3,7,8,4},{1,3,4,2},{5,6,8,7}}
    local faces = {}
    for _, ids in ipairs(indices) do
        local points = {} for _, i in ipairs(ids) do points[#points+1] = p[i] end
        faces[#faces+1] = {points=points,mat=0}
    end
    return G.Prepare(faces)
end

local function clip(piece,n,d)
    local faces, cap = {}, {}
    for _, face in ipairs(piece.faces) do
        local output, points = {}, face.points
        for i, a in ipairs(points) do
            local b = points[i%#points+1]
            local da, db = n:Dot(a)-d, n:Dot(b)-d
            if da <= EPS then output[#output+1] = a end
            if (da < -EPS and db > EPS) or (da > EPS and db < -EPS) then
                local intersection = a+(b-a)*(da/(da-db))
                output[#output+1] = intersection cap[#cap+1] = intersection
            elseif math.abs(da) <= EPS then cap[#cap+1] = a end
        end
        if #output >= 3 then
            faces[#faces+1] = {points=output,mat=face.mat,uv=face.uv,nodraw=face.nodraw,
                origin_face=face.origin_face or (face.source_meta and face)}
        end
    end
    cap = unique(cap)
    if #cap >= 3 then
        local center = Vector() for _, p in ipairs(cap) do center = center+p end
        center = center/#cap
        local u = (cap[1]-center):GetNormalized()
        local v = n:Cross(u):GetNormalized()
        table.sort(cap,function(a,b)
            local x,y = a-center,b-center
            return math.atan2(x:Dot(v),x:Dot(u)) < math.atan2(y:Dot(v),y:Dot(u))
        end)
        faces[#faces+1] = {points=cap,mat=1}
    end
    return G.Prepare(faces)
end

local function split(piece,n,d)
    local minimum,maximum = math.huge,-math.huge
    for _, p in ipairs(piece.vertices) do
        local distance = n:Dot(p)-d
        minimum = math.min(minimum,distance) maximum = math.max(maximum,distance)
    end
    if maximum <= EPS then return piece,nil end
    if minimum >= -EPS then return nil,piece end
    return clip(piece,n,d),clip(piece,-n,-d)
end

local directions = {Vector(1,0,0),Vector(-1,0,0),Vector(0,1,0),Vector(0,-1,0),
                    Vector(0,0,1),Vector(0,0,-1)}
for x=-1,1,2 do for y=-1,1,2 do for z=-1,1,2 do
    directions[#directions+1] = Vector(x,y,z):GetNormalized()
end end end

local boreSides={.91,.98,.90,.96,.93,.99,.89,.95}

function G.CutterPlanes(radius,seed,normal,bore)
    if bore and normal and normal:LengthSqr()>.5 then
        local axis=normal:GetNormalized()
        local reference=math.abs(axis.z)>.9 and Vector(1,0,0) or Vector(0,0,1)
        local u=axis:Cross(reference):GetNormalized()
        local v=axis:Cross(u)
        -- Retain the solid behind the cut before processing the side planes.
        -- Fixed side orientations let aligned hits extend an existing bore
        -- with the same footprint. The far rim tapers into the end face.
        local planes={{normal=-axis,d=radius*.96},{normal=axis,d=radius}}
        local bevels={}
        for i,scale in ipairs(boreSides) do
            local angle=(i-1)*math.pi/4
            local side=u*math.cos(angle)+v*math.sin(angle)
            planes[#planes+1]={normal=side,d=radius*scale}
            bevels[i]={normal=(side-axis):GetNormalized(),d=radius*(scale+.80)/math.sqrt(2)}
        end
        for _,plane in ipairs(bevels) do planes[#planes+1]=plane end
        return planes
    end
    local planes={}
    local state=seed or 0
    local function random()
        state=(state*16807)%2147483647
        return state/2147483647
    end
    local rotation=state~=0 and Angle(random()*40-20,random()*360,random()*40-20) or nil
    for _,direction in ipairs(directions) do
        local n=Vector(direction.x,direction.y,direction.z)
        if rotation then n:Rotate(rotation) end
        planes[#planes+1]={normal=n,d=radius*(rotation and (0.88+random()*0.24) or 1)}
    end
    if rotation and normal then
        -- Vary the silhouette without letting a wide first blast unexpectedly
        -- punch all the way through this wall. Depth follows the impact normal.
        local n=normal:GetNormalized()
        planes[#planes+1]={normal=n,d=radius*(0.92+random()*0.08)}
        planes[#planes+1]={normal=-n,d=radius*(0.92+random()*0.08)}
    end
    return planes
end

local function mergeConvex(a,b)
    if a.low.x>b.high.x+EPS or b.low.x>a.high.x+EPS or
        a.low.y>b.high.y+EPS or b.low.y>a.high.y+EPS or
        a.low.z>b.high.z+EPS or b.low.z>a.high.z+EPS then return end
    for ai,af in ipairs(a.faces) do for bi,bf in ipairs(b.faces) do
        if af.normal:Dot(bf.normal)<-.99999 and math.abs(af.d+bf.d)<.01 and #af.points==#bf.points then
            local same=true
            for _,p in ipairs(af.points) do
                local found=false
                for _,q in ipairs(bf.points) do if p:DistToSqr(q)<.0001 then found=true break end end
                if not found then same=false break end
            end
            if same then
                for i,face in ipairs(a.faces) do if i~=ai then
                    for _,p in ipairs(b.vertices) do if face.normal:Dot(p)-face.d>.01 then same=false break end end
                    if not same then break end
                end end
                if same then for i,face in ipairs(b.faces) do if i~=bi then
                    for _,p in ipairs(a.vertices) do if face.normal:Dot(p)-face.d>.01 then same=false break end end
                    if not same then break end
                end end end
                if same then
                    local faces={}
                    for i,face in ipairs(a.faces) do if i~=ai then faces[#faces+1]=face end end
                    for i,face in ipairs(b.faces) do if i~=bi then faces[#faces+1]=face end end
                    local merged=G.Prepare(faces)
                    if merged and math.abs(merged.volume-a.volume-b.volume)<math.max(.1,(a.volume+b.volume)*.000001) then return merged end
                end
            end
        end
    end end
end

function G.MergeConvexPieces(pieces,checkpoint)
    local active,bins,queue={},{},{}
    local function key(x,y,z) return x..':'..y..':'..z end
    local function centers(piece)
        local result={}
        for _,face in ipairs(piece.faces) do
            local p=Vector()
            for _,vertex in ipairs(face.points) do p=p+vertex end
            result[#result+1]=p/#face.points
        end
        return result
    end
    local function register(index,piece)
        local row={index=index,piece=piece,centers=centers(piece)}
        active[index]=row
        for _,p in ipairs(row.centers) do
            local id=key(math.floor(p.x/16),math.floor(p.y/16),math.floor(p.z/16))
            local bin=bins[id] or {} bins[id]=bin bin[#bin+1]=row
        end
        queue[#queue+1]=row
    end
    for i,p in ipairs(pieces) do
        register(i,p)
        if checkpoint then checkpoint() end
    end
    for _,row in ipairs(queue) do
        if active[row.index]==row then
            local candidates,seen={},{}
            -- A full shared face has the same centroid to within the vertex
            -- tolerance. Search nearby bins before running the exact test.
            for _,p in ipairs(row.centers) do
                for x=math.floor((p.x-.02)/16),math.floor((p.x+.02)/16) do
                    for y=math.floor((p.y-.02)/16),math.floor((p.y+.02)/16) do
                        for z=math.floor((p.z-.02)/16),math.floor((p.z+.02)/16) do
                            for _,other in ipairs(bins[key(x,y,z)] or {}) do
                                local j=other.index
                                if row~=other and active[j]==other and not seen[j] then
                                    candidates[#candidates+1]=j seen[j]=true
                                end
                            end
                            if checkpoint then checkpoint() end
                        end
                    end
                end
            end
            table.sort(candidates)
            for _,j in ipairs(candidates) do
                local i=row.index
                local first,last=math.min(i,j),math.max(i,j)
                local merged=mergeConvex(active[first].piece,active[last].piece)
                if checkpoint then checkpoint() end
                if merged then
                    active[last]=nil
                    register(first,merged)
                    break
                end
            end
        end
    end
    local output={}
    for i=1,#pieces do if active[i] then output[#output+1]=active[i].piece end end
    return output
end

local function outsideCutter(piece,planes,center)
    for _,plane in ipairs(planes) do
        local n=plane.normal
        local limit=n:Dot(center)+plane.d+EPS
        local outside=true
        for _,p in ipairs(piece.vertices) do
            if n:Dot(p)<=limit then outside=false break end
        end
        if outside then return true end
    end
    return false
end

function G.Subtract(pieces,center,radius,seed,normal,checkpoint,bore)
    local output = {}
    local planes=G.CutterPlanes(radius,seed,normal,bore)
    local bound=seed and seed~=0 and radius*2 or radius
    for _, piece in ipairs(pieces) do
        if center.x+bound < piece.low.x or center.x-bound > piece.high.x or
           center.y+bound < piece.low.y or center.y-bound > piece.high.y or
           center.z+bound < piece.low.z or center.z-bound > piece.high.z or outsideCutter(piece,planes,center) then
            output[#output+1] = piece
        else
            local remaining = piece
            local outsidePieces={}
            for _, plane in ipairs(planes) do
                if not remaining then break end
                local n=plane.normal
                local inside,outside = split(remaining,n,n:Dot(center)+plane.d)
                if outside then outsidePieces[#outsidePieces+1] = outside end
                remaining = inside
            end
            if not remaining then
                -- Broad-phase overlap is not a real cut. Preserve this convex
                -- piece instead of accumulating partitions from a missed blast.
                output[#output+1]=piece
            else
                -- The remainder is inside every cutter plane and is discarded.
                for _,outside in ipairs(outsidePieces) do output[#output+1]=outside end
            end
        end
        if #output > G.MaxPieces*2 then return nil,'Wall complexity limit reached; reset to continue.' end
        if checkpoint then checkpoint() end
    end
    if #output>G.MaxPieces then output=G.MergeConvexPieces(output,checkpoint) end
    if #output>G.MaxPieces then return nil,'Wall complexity limit reached; reset to continue.' end
    return output
end

function G.Volume(pieces)
    local volume = 0 for _, p in ipairs(pieces) do volume = volume+p.volume end
    return volume
end

function G.Trace(pieces,start,delta,extents)
    extents = extents or Vector()
    local earliest,hitNormal = 1,nil
    for _, piece in ipairs(pieces or {}) do
        local enter,leave,normal,valid = 0,1,nil,true
        for _, plane in ipairs(piece.planes) do
            local n = plane.normal
            local expanded = plane.d+math.abs(n.x)*extents.x+math.abs(n.y)*extents.y+math.abs(n.z)*extents.z
            local distance,speed = n:Dot(start)-expanded,n:Dot(delta)
            if math.abs(speed) < 0.000001 then
                if distance > EPS then valid=false break end
            else
                local t = -distance/speed
                if speed < 0 then
                    if t > enter then enter,normal=t,n end
                else leave=math.min(leave,t) end
                if enter > leave+0.000001 then valid=false break end
            end
        end
        if valid and enter >= 0 and enter < earliest and leave >= 0 then
            earliest,hitNormal = enter,normal or -delta:GetNormalized()
        end
    end
    if not hitNormal then return nil end
    return {Fraction=earliest,HitPos=start+delta*earliest,Normal=hitNormal}
end

function G.ClosestSurface(pieces,point,checkpoint)
    -- Closest point on convex polygon: project to its plane or clamp to an edge.
    local best,bestNormal,bestDistance = nil,nil,math.huge
    for _, piece in ipairs(pieces) do for _, face in ipairs(piece.faces) do
        local projected = point-face.normal*(face.normal:Dot(point)-face.d)
        local inside = true
        for i,a in ipairs(face.points) do
            local b=face.points[i%#face.points+1]
            if (b-a):Cross(projected-a):Dot(face.normal) < -EPS then inside=false break end
        end
        if inside and point:DistToSqr(projected) < bestDistance then
            best,bestNormal,bestDistance=projected,face.normal,point:DistToSqr(projected)
        end
        if not inside then for i,a in ipairs(face.points) do
            local b=face.points[i%#face.points+1] local edge=b-a
            local candidate=a+edge*math.Clamp((point-a):Dot(edge)/edge:LengthSqr(),0,1)
            local distance=point:DistToSqr(candidate)
            if distance < bestDistance then best,bestNormal,bestDistance=candidate,face.normal,distance end
        end end
        if checkpoint then checkpoint() end
    end end
    return best,bestNormal
end

-- Wall history operations (RF-070/RF-071). A cut subtracts a blast volume.
-- KEEP retains only the island whose centroid is nearest op.center and moves
-- the local origin to that point (a detached chunk's own entity frame); later
-- cuts are recorded in that new frame. DROP removes the nearest island.
G.OP_CUT, G.OP_KEEP, G.OP_DROP = 0, 1, 2
G.MaxOps = 1000

local function overlapArea(face,other)
    local polygon=face.points
    local center=Vector() for _,p in ipairs(other.points) do center=center+p end
    center=center/#other.points
    for i,a in ipairs(other.points) do
        local b=other.points[i%#other.points+1]
        local n=(b-a):Cross(face.normal)
        if n:LengthSqr()>1e-8 then
            n:Normalize() local d=n:Dot(a)
            if n:Dot(center)-d<0 then n=-n d=-d end
            local clipped={}
            for j,p in ipairs(polygon) do
                local q=polygon[j%#polygon+1]
                local dp,dq=n:Dot(p)-d,n:Dot(q)-d
                if dp>=-EPS then clipped[#clipped+1]=p end
                if (dp<-EPS and dq>EPS) or (dp>EPS and dq<-EPS) then clipped[#clipped+1]=p+(q-p)*(dp/(dp-dq)) end
            end
            polygon=clipped
            if #polygon<3 then return 0 end
        end
    end
    local sum=Vector()
    for i=2,#polygon-1 do sum=sum+(polygon[i]-polygon[1]):Cross(polygon[i+1]-polygon[1]) end
    return sum:Length()*.5
end

-- Solid contact: shared face area, or overlapping volumes (source brushes
-- may overlap). Edge/point contact and gaps do not connect pieces.
local CONTACT=0.01
local function connected(a,b)
    if a.low.x>b.high.x+CONTACT or b.low.x>a.high.x+CONTACT or
       a.low.y>b.high.y+CONTACT or b.low.y>a.high.y+CONTACT or
       a.low.z>b.high.z+CONTACT or b.low.z>a.high.z+CONTACT then return false end
    local touching=false
    for pass=1,2 do
        local p,q = pass==1 and a or b, pass==1 and b or a
        for _,face in ipairs(p.faces) do
            local minimum=math.huge
            for _,v in ipairs(q.vertices) do
                local distance=face.normal:Dot(v)-face.d
                if distance<minimum then minimum=distance end
            end
            if minimum>CONTACT then return false end
            if minimum>=-CONTACT then
                for _,other in ipairs(q.faces) do
                    if other.normal:Dot(face.normal)<-0.9999 and math.abs(other.d+face.d)<CONTACT and
                        overlapArea(face,other)>0.25 then return true end
                end
                touching=true
            end
        end
    end
    return not touching
end

local function pieceCenter(piece)
    local c=Vector() for _,v in ipairs(piece.vertices) do c=c+v end
    return c/#piece.vertices
end

-- Connected groups of pieces: {indices,volume,centroid}, in first-piece order.
function G.Islands(pieces,contacts,checkpoint)
    local parent={}
    for i=1,#pieces do parent[i]=i end
    local function find(i)
        while parent[i]~=i do parent[i]=parent[parent[i]] i=parent[i] end
        return i
    end
    for i=1,#pieces-1 do for j=i+1,#pieces do
        local ri,rj=find(i),find(j)
        if ri~=rj then
            local a,b=pieces[i],pieces[j]
            local row=contacts and contacts[a]
            if contacts and not row then
                row=setmetatable({},{__mode='k'}) contacts[a]=row
            end
            local adjacent=row and row[b]
            if adjacent==nil then
                adjacent=connected(a,b)
                if row then row[b]=adjacent end
            end
            if adjacent then
                if ri<rj then parent[rj]=ri else parent[ri]=rj end
            end
        end
        if checkpoint and j%16==0 then checkpoint() end
    end end
    local islands,byRoot={},{}
    for i,piece in ipairs(pieces) do
        local root=find(i)
        local island=byRoot[root]
        if not island then
            island={indices={},volume=0,weighted=Vector()}
            byRoot[root]=island islands[#islands+1]=island
        end
        island.indices[#island.indices+1]=i
        island.volume=island.volume+piece.volume
        island.weighted=island.weighted+pieceCenter(piece)*piece.volume
    end
    for _,island in ipairs(islands) do
        island.centroid=island.volume>0 and island.weighted/island.volume or pieceCenter(pieces[island.indices[1]])
        island.weighted=nil
    end
    return islands
end

function G.NearestIsland(islands,point)
    local best,distance
    for _,island in ipairs(islands) do
        local d=island.centroid:DistToSqr(point)
        if not distance or d<distance then best,distance=island,d end
    end
    return best
end

-- Move the local origin to offset: points shift by -offset, texture offsets
-- compensate so faces keep their exact texturing.
function G.Translate(pieces,offset,checkpoint)
    local output={}
    for _,piece in ipairs(pieces) do
        local faces={}
        for _,face in ipairs(piece.faces) do
            local points={} for i,p in ipairs(face.points) do points[i]=p-offset end
            local uv=face.uv
            if uv then
                uv={u=uv.u,v=uv.v,uo=uv.uo+offset:Dot(uv.u),vo=uv.vo+offset:Dot(uv.v),width=uv.width,height=uv.height}
            end
            faces[#faces+1]={points=points,mat=face.mat,uv=uv,nodraw=face.nodraw}
        end
        local moved=G.Prepare(faces)
        if moved then output[#output+1]=moved end
        if checkpoint then checkpoint() end
    end
    return output
end

function G.Bounds(pieces)
    local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    for _,p in ipairs(pieces) do for _,axis in ipairs({'x','y','z'}) do
        low[axis]=math.min(low[axis],p.low[axis]) high[axis]=math.max(high[axis],p.high[axis])
    end end
    if low.x>high.x then return Vector(),Vector() end
    return low,high
end

function G.ApplyOp(pieces,op,checkpoint)
    local kind=op.kind or G.OP_CUT
    if kind==G.OP_CUT then return G.Subtract(pieces,op.center,op.radius,op.seed,op.normal,checkpoint,op.bore) end
    local island=G.NearestIsland(G.Islands(pieces,nil,checkpoint),op.center)
    if not island then return nil,'No island for this operation.' end
    local member={} for _,i in ipairs(island.indices) do member[i]=true end
    local output={}
    for i,piece in ipairs(pieces) do
        if (kind==G.OP_KEEP)==(member[i]==true) then output[#output+1]=piece end
    end
    if kind==G.OP_KEEP then output=G.Translate(output,op.center,checkpoint) end
    return output
end

function G.Replay(cuts,low,high,initialPieces)
    local pieces = initialPieces or {G.Box(low,high)}
    for _, op in ipairs(cuts) do
        local result = G.ApplyOp(pieces,op)
        if not result then return nil end
        pieces = result
    end
    return pieces
end

-- Cut records expressed in the final local frame (for scorch projection):
-- each KEEP after a cut moved the origin by its center.
function G.CutsInFinalFrame(ops)
    local output,offset={},Vector()
    for i=#ops,1,-1 do
        local op=ops[i]
        local kind=op.kind or G.OP_CUT
        if kind==G.OP_KEEP then offset=offset+op.center
        elseif kind==G.OP_CUT then
            table.insert(output,1,{center=op.center-offset,radius=op.radius,seed=op.seed,normal=op.normal,kind=kind})
        end
    end
    return output
end

-- Hardness (0-100, port calibration inspired by retail GeoMod hardness 0-100):
-- 50 keeps the original crater size; low hardness carves larger craters and
-- weighs less, high hardness only chips and weighs more.
G.DefaultHardness=50
function G.ClampHardness(value) return math.Clamp(tonumber(value) or G.DefaultHardness,0,100) end
function G.HardnessCraterScale(hardness)
    hardness=G.ClampHardness(hardness)
    if hardness<=50 then return Lerp(hardness/50,1.5,1) end
    return Lerp((hardness-50)/50,1,0.3)
end
local CUBIC_INCH_M3,MASS_SCALE=1.6387e-5,0.25
function G.HardnessMass(volume,hardness)
    local rho=500+G.ClampHardness(hardness)*30 -- kg/m^3, 500 (pumice-like) to 3500
    return math.Clamp(volume*CUBIC_INCH_M3*rho*MASS_SCALE,1,50000)
end
