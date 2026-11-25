-- Read convex solids and texture axes from a compiled brush model. Layouts:
-- ValveSoftware/source-sdk-2013/src/public/bspfile.h (BSP v20).
include('rf_geomod/geometry.lua')
local cache={}
function RFGeoMod.ReadBrushModel(model,cutMaterial)
    local index=tonumber(tostring(model):match('^%*(%d+)$'))
    if not index or index<1 then return nil,'Expected a compiled brush model (*N).' end
    local key=game.GetMap()..':'..model..':'..cutMaterial
    if cache[key] then return cache[key] end
    local f=file.Open('maps/'..game.GetMap()..'.bsp','rb','GAME')
    if not f then return nil,'Cannot read the mounted map BSP.' end
    local ok,result=xpcall(function()
        if f:Read(4)~='VBSP' or f:ReadLong()~=20 then error('Only Source BSP v20 is supported.') end
        local lumps={}
        for i=0,63 do
            lumps[i]={offset=f:ReadLong(),size=f:ReadLong(),version=f:ReadLong(),compressed=f:ReadLong()}
        end
        local function record(lump,index,stride)
            local l=lumps[lump]
            if l.compressed~=0 then error('Compressed BSP lumps are not supported; use an ordinary Hammer compile.') end
            if index<0 or (index+1)*stride>l.size then error('Invalid BSP record in lump '..lump) end
            f:Seek(l.offset+index*stride)
        end
        local function vector() return Vector(f:ReadFloat(),f:ReadFloat(),f:ReadFloat()) end
        local function ushort() local n=f:ReadShort() return n<0 and n+65536 or n end
        record(14,index,48)
        vector() vector() vector()
        local head=f:ReadLong()
        local firstFace,numFaces=f:ReadLong(),f:ReadLong()
        -- This compiler leaves brushside.dispinfo at zero even without a
        -- displacement. The actual rendered face's dispinfo is authoritative.
        for i=firstFace,firstFace+numFaces-1 do
            record(7,i,56) f:Seek(f:Tell()+12)
            if f:ReadShort()>=0 then error('Displacements cannot be imported as destructible solids.') end
        end
        local ids,visited={},{}
        local leafStride=lumps[10].version==0 and 56 or 32
        local function visit(node)
            if visited[node] then return end visited[node]=true
            if node>=0 then
                record(5,node,32) f:ReadLong()
                local a,b=f:ReadLong(),f:ReadLong() visit(a) visit(b)
            else
                record(10,-node-1,leafStride) f:Seek(f:Tell()+24)
                local first,count=ushort(),ushort()
                for i=first,first+count-1 do record(17,i,2) ids[ushort()]=true end
            end
        end
        visit(head)
        local names={false,cutMaterial}
        local materialIds={}
        local textureCache={}
        local function texture(id)
            if id<0 then return {nodraw=true} end
            if textureCache[id] then return textureCache[id] end
            record(6,id,72)
            local u,uo=vector(),f:ReadFloat()
            local v,vo=vector(),f:ReadFloat()
            f:Seek(f:Tell()+32)
            local flags,data=f:ReadLong(),f:ReadLong()
            record(2,data,32) vector()
            local stringId=f:ReadLong()
            local width,height=f:ReadLong(),f:ReadLong()
            record(44,stringId,4) local offset=f:ReadLong()
            if offset<0 or offset>=lumps[43].size then error('Invalid texture string offset.') end
            f:Seek(lumps[43].offset+offset)
            local chars={}
            for i=1,1024 do local c=f:Read(1) if not c or c=='\0' then break end chars[#chars+1]=c end
            local name=table.concat(chars):lower()
            local mat=materialIds[name]
            if not mat then
                if not names[1] then names[1]=name mat=0 else mat=#names names[#names+1]=name end
                materialIds[name]=mat
            end
            local t={mat=mat,nodraw=bit.band(flags,0x80)~=0,
                uv={u=u,v=v,uo=uo,vo=vo,width=math.max(width,1),height=math.max(height,1)}}
            textureCache[id]=t return t
        end
        local function plane(id)
            record(1,id,20) return {normal=vector(),d=f:ReadFloat()}
        end
        local pieces={}
        local ordered={} for id in pairs(ids) do ordered[#ordered+1]=id end table.sort(ordered)
        for _,id in ipairs(ordered) do
            record(18,id,12)
            local first,count,contents=f:ReadLong(),f:ReadLong(),f:ReadLong()
            if bit.band(contents,CONTENTS_SOLID)~=0 then
                local sides={}
                for i=first,first+count-1 do
                    record(19,i,8)
                    local p,tex=ushort(),f:ReadShort() f:ReadShort() local bevel=ushort()
                    if bevel==0 then
                        local side=plane(p) local t=texture(tex)
                        side.mat,side.uv,side.nodraw=t.mat or 0,t.uv,t.nodraw
                        sides[#sides+1]=side
                    end
                end
                if #sides>64 then error('Brush has too many planes.') end
                local points={}
                for a=1,#sides-2 do for b=a+1,#sides-1 do for c=b+1,#sides do
                    local pa,pb,pc=sides[a],sides[b],sides[c]
                    local bc=pb.normal:Cross(pc.normal) local determinant=pa.normal:Dot(bc)
                    if math.abs(determinant)>0.000001 then
                        local p=(bc*pa.d+pc.normal:Cross(pa.normal)*pb.d+pa.normal:Cross(pb.normal)*pc.d)/determinant
                        local inside=true for _,s in ipairs(sides) do
                            if s.normal:Dot(p)-s.d>0.02 then inside=false break end
                        end
                        if inside then
                            local duplicate=false for _,old in ipairs(points) do if old:DistToSqr(p)<0.0001 then duplicate=true break end end
                            if not duplicate then points[#points+1]=p end
                        end
                    end
                end end end
                local faces={}
                for _,side in ipairs(sides) do
                    local polygon,center={},Vector()
                    for _,p in ipairs(points) do if math.abs(side.normal:Dot(p)-side.d)<0.03 then
                        polygon[#polygon+1]=p center=center+p
                    end end
                    if #polygon>=3 then
                        center=center/#polygon
                        local u=(polygon[1]-center):GetNormalized() local v=side.normal:Cross(u)
                        table.sort(polygon,function(a,b)
                            local da,db=a-center,b-center
                            return math.atan2(da:Dot(v),da:Dot(u))<math.atan2(db:Dot(v),db:Dot(u))
                        end)
                        faces[#faces+1]={points=polygon,mat=side.mat,uv=side.uv,nodraw=side.nodraw}
                    end
                end
                local piece=RFGeoMod.Prepare(faces)
                if piece then pieces[#pieces+1]=piece end
            end
        end
        if #pieces==0 then error('Brush model contains no supported solid brushes.') end
        if #pieces>RFGeoMod.MaxPieces then error('Brush model exceeds the convex-piece limit.') end
        names[1]=names[1] or 'dev/dev_measurewall01a'
        local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
        for _,p in ipairs(pieces) do for _,axis in ipairs({'x','y','z'}) do
            low[axis]=math.min(low[axis],p.low[axis]) high[axis]=math.max(high[axis],p.high[axis])
        end end
        return {pieces=pieces,materials=names,low=low,high=high}
    end,debug.traceback)
    f:Close()
    if not ok then return nil,result end
    cache[key]=result return result
end
