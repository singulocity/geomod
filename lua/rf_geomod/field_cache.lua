-- Immutable initial-state caches. No Lua/native objects are deserialized.
-- Shipped data_static files are read-only; generated files live under DATA.
local G=RFGeoMod
local C={Version=5,io={},errors={},stats={geometry_hits=0,render_hits=0,misses=0,writes=0,rejected=0}}
G.FieldCache=C
local ROOT='rf_geomod_cache/'
local SHIP='data_static/rf_geomod/'
local function validKey(key) return type(key)=='string' and #key==64 and key:match('^[a-f0-9]+$') end
local function basename(key,kind)
    assert(validKey(key),'Invalid field cache key')
    assert(kind=='g' or kind=='r0' or kind=='r1','Invalid field cache kind')
    return game.GetMap()..'_'..key..'_'..kind..'.dat'
end
function C.LocalPath(key,kind) return ROOT..basename(key,kind) end
function C.ShipPath(key,kind) return SHIP..basename(key,kind) end
local signature
function C.Signature()
    if signature then return signature end
    local bsp=assert(file.Read('maps/'..game.GetMap()..'.bsp','GAME'),'Map unavailable')
    local parts={tostring(C.Version),bsp}
    for _,name in ipairs({'geometry','bsp','surface','field','field_queries','field_groups','field_sources','field_cache','field_runtime','field_render','lightmaps'}) do
        parts[#parts+1]=assert(file.Read('rf_geomod/'..name..'.lua','LUA'),'Cache source unavailable: '..name):gsub('\r\n','\n')
    end
    signature=util.SHA256(table.concat(parts,'\0'))
    return signature
end
function C.Key(data,volume)
    -- Arrays only: JSON dictionary iteration order is not a stable fingerprint.
    local sources,members={},{}
    for _,s in ipairs(data.sources) do sources[#sources+1]={s.model,s.pos,s.ang} end
    for _,m in ipairs(data.members) do members[#members+1]={m.s,m.p} end
    return util.SHA256(util.TableToJSON({C.Version,C.Signature(),sources,members,data.materials,
        {data.config.hardness,data.config.cut_material,data.config.cut_repeat},
        {volume.spacing.x,volume.spacing.y,volume.spacing.z},volume.chunkCells}))
end
function C.RenderKind() return GetConVar('mat_hdr_level'):GetInt()>0 and 'r1' or 'r0' end
local function close(owner,handle,remove)
    handle.file:Close()
    local list=C.io[owner] if list then list[handle]=nil if not next(list) then C.io[owner]=nil end end
    if remove and handle.pending then file.Delete(handle.path) end
end
function C.Cancel(owner)
    for handle in pairs(C.io[owner] or {}) do handle.file:Close() if handle.pending then file.Delete(handle.path) end end
    C.io[owner]=nil
end
local function own(owner,f,path,pending)
    local h={file=f,path=path,pending=pending}
    C.io[owner]=C.io[owner] or {} C.io[owner][h]=true return h
end
local function report(message)
    C.errors[#C.errors+1]=tostring(message)
    ErrorNoHalt('[GeoMod cache] '..tostring(message)..'\n')
end
local function number(f)
    local n=f:ReadFloat()
    assert(n and n==n and math.abs(n)<1e9,'Invalid cached number') return n
end
local function count(f,maximum)
    local n=f:ReadLong() assert(n and n>=0 and n<=maximum,'Invalid cached count') return n
end
local function vector(f) return Vector(number(f),number(f),number(f)) end
local function putVector(f,p) f:WriteFloat(p.x) f:WriteFloat(p.y) f:WriteFloat(p.z) end
local function stringRead(f) local n=count(f,1024) if n==0 then return '' end local s=f:Read(n) assert(s and #s==n,'Truncated cached string') return s end
local function stringWrite(f,s) f:WriteLong(#s) f:Write(s) end
local function faces(volume)
    local list,ids={},{}
    for _,piece in ipairs(volume.pieces) do for _,face in ipairs(piece.faces) do list[#list+1]=face ids[face]=#list end end
    return list,ids
end
local function chunks(volume)
    local list,ids=volume:AllChunks(),{}
    for _,c in ipairs(list) do ids[c.key]=c end return list,ids
end
-- The payload is already read once for its checksum. Decode that buffer rather
-- than issuing millions of small native filesystem reads. All arithmetic below
-- reconstructs an IEEE float32 exactly in Lua's float64 number type.
local Buffer={} Buffer.__index=Buffer
local scales={} for e=1,254 do scales[e]=2^(e-150) end
function Buffer:Read(n)
    local at=self.at assert(at+n-1<=#self.data,'Truncated cache')
    self.at=at+n return self.data:sub(at,at+n-1)
end
function Buffer:ReadByte()
    local n=self.data:byte(self.at) assert(n,'Truncated cache') self.at=self.at+1 return n
end
function Buffer:ReadLong()
    local at=self.at local a,b,c,d=self.data:byte(at,at+3) assert(d,'Truncated cache') self.at=at+4
    local n=a+b*256+c*65536+d*16777216 return n>=2147483648 and n-4294967296 or n
end
function Buffer:ReadFloat()
    local at=self.at local a,b,c,d=self.data:byte(at,at+3) assert(d,'Truncated cache') self.at=at+4
    local exponent=(d%128)*2+math.floor(c/128)
    local mantissa=a+b*256+(c%128)*65536 local sign=d>=128 and -1 or 1
    if exponent==0 then return sign*mantissa*2^-149 end
    if exponent==255 then return mantissa==0 and sign*math.huge or 0/0 end
    return sign*(mantissa+8388608)*scales[exponent]
end
function Buffer:Tell() return self.at-1 end
function Buffer:Size() return #self.data end
function Buffer:Close() self.data='' end
function C.PreparePhysics(triangles,pool,checkpoint)
    pool=pool or {}
    local vertices={} local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
    local n=0
    for _,t in ipairs(triangles) do
        local snapped={}
        for i=1,3 do
            local v=pool[n+i] or {pos=Vector()} pool[n+i]=v
            local p=t[i]
            v.pos.x=math.Round(p.x*32)/32 v.pos.y=math.Round(p.y*32)/32 v.pos.z=math.Round(p.z*32)/32
            snapped[i]=v
        end
        -- Source rejects these microscopic/collapsed triangles after snapping.
        -- Filter only the collision copy; the visible surface stays intact.
        local a,b,c=snapped[1].pos,snapped[2].pos,snapped[3].pos
        if (b-a):Cross(c-a):LengthSqr()>4e-6 then
            for i=1,3 do
                n=n+1 local v=snapped[i] vertices[n]=v
                low.x=math.min(low.x,v.pos.x) low.y=math.min(low.y,v.pos.y) low.z=math.min(low.z,v.pos.z)
                high.x=math.max(high.x,v.pos.x) high.y=math.max(high.y,v.pos.y) high.z=math.max(high.z,v.pos.z)
            end
        end
        checkpoint()
    end
    if n==0 then low,high=Vector(),Vector() end
    return {vertices=vertices,low=low,high=high}
end
local function decode(owner,kind,checkpoint,fn)
    local key=owner.FieldData.cache_key
    if not validKey(key) then return nil end
    for _,location in ipairs({{C.ShipPath(key,kind),'GAME','shipped'},{C.LocalPath(key,kind),'DATA','local'}}) do
        local path,realm,source=unpack(location)
        if file.Exists(path,realm) then
            local metadata=util.JSONToTable(file.Read(path..'.json',realm) or '')
            local bytes=type(metadata)=='table' and file.Size(path,realm)<512*1024*1024 and file.Read(path,realm)
            local okay=bytes and metadata.key==key and metadata.version==C.Version and metadata.kind==kind and
                metadata.bytes==#bytes and metadata.sha256==util.SHA256(bytes)
            if okay then
                local f=setmetatable({data=bytes,at=1},Buffer)
                if f then
                    local h=own(owner,f,path,false)
                    local ok,result=pcall(function()
                        assert(f:Read(4)=='RFGC' and f:ReadLong()==C.Version and stringRead(f)==key and stringRead(f)==kind,'Invalid cache header')
                        local result=fn(f,checkpoint)
                        assert(f:Read(4)=='DONE' and f:Tell()==f:Size(),'Incomplete cache')
                        return result
                    end)
                    close(owner,h,false)
                    if ok then
                        C.stats[kind=='g' and 'geometry_hits' or 'render_hits']=C.stats[kind=='g' and 'geometry_hits' or 'render_hits']+1
                        return result,source
                    end
                end
            end
            C.stats.rejected=C.stats.rejected+1
            -- A rejected shipped file is never modified. Only our generated cache is replaceable.
            if realm=='DATA' then file.Delete(path) file.Delete(path..'.json') end
        end
    end
    C.stats.misses=C.stats.misses+1
end
local function encode(owner,kind,checkpoint,fn)
    local key=owner.FieldData.cache_key
    if not validKey(key) then return false end
    file.CreateDir('rf_geomod_cache')
    local target=C.LocalPath(key,kind)
    local path=target..(SERVER and '.server.pending.dat' or '.client.pending.dat')
    local f=file.Open(path,'wb','DATA')
    if not f then report('Cannot write '..path) return false end
    local h=own(owner,f,path,true)
    local ok,err=pcall(function()
        f:Write('RFGC') f:WriteLong(C.Version) stringWrite(f,key) stringWrite(f,kind)
        fn(f,checkpoint) f:Write('DONE')
    end)
    close(owner,h,not ok)
    if not ok then report(err) return false end
    local bytes=file.Read(path,'DATA')
    if not bytes then file.Delete(path) report('Cannot verify '..path) return false end
    local meta={version=C.Version,key=key,kind=kind,map=game.GetMap(),bytes=#bytes,sha256=util.SHA256(bytes)}
    -- The two realms may finish the same geometry on a listen server. Commit a
    -- complete file and checksum together, with no coroutine yield in between.
    if file.Exists(target,'DATA') then file.Delete(target) end
    if not file.Rename(path,target) then file.Delete(path) report('Cannot commit '..target) return false end
    if not file.Write(target..'.json',util.TableToJSON(meta)) then report('Cannot write checksum '..target) return false end
    C.stats.writes=C.stats.writes+1 return true
end
function C.LoadGeometry(wall,checkpoint)
    local volume=wall.FieldVolume
    local faceList=faces(volume) local all,allowed=chunks(volume)
    local result,source=decode(wall,'g',checkpoint,function(f,check)
        assert(count(f,4096)==#all,'Chunk layout changed')
        local result={} local total=0
        for _=1,#all do
            local key=stringRead(f) assert(allowed[key] and not result[key],'Invalid cached chunk')
            local n=count(f,1000000) total=total+n assert(total<=4000000,'Geometry cache too large')
            local triangles={}
            for i=1,n do
                local mat=count(f,#wall.WallMaterialNames-1) local face=count(f,#faceList)
                triangles[i]={vector(f),vector(f),vector(f),normal=vector(f),mat=mat,face=faceList[face]}
                if i%64==0 then check() end
            end
            local physics={low=vector(f),high=vector(f),vertices={}}
            local physicsCount=count(f,n*3)
            assert(physicsCount%3==0,'Invalid collision buffer size')
            for i=1,physicsCount do physics.vertices[i]={pos=vector(f)} if i%128==0 then check() end end
            result[key]={triangles=triangles,revision=0,physics=physics} check()
        end
        return result
    end)
    if result then volume.chunks=result end
    return result,source
end
function C.SaveGeometry(wall,checkpoint)
    if wall.FieldVolume.revision~=0 then return false end
    local _,ids=faces(wall.FieldVolume) local all=chunks(wall.FieldVolume)
    return encode(wall,'g',checkpoint,function(f,check)
        f:WriteLong(#all)
        for _,chunk in ipairs(all) do
            local row=assert(wall.FieldVolume.chunks[chunk.key],'Incomplete initial geometry')
            stringWrite(f,chunk.key) f:WriteLong(#row.triangles)
            for i,t in ipairs(row.triangles) do
                f:WriteLong(t.mat) f:WriteLong(t.face and assert(ids[t.face],'Unmapped source face') or 0)
                putVector(f,t[1]) putVector(f,t[2]) putVector(f,t[3]) putVector(f,t.normal)
                if i%64==0 then check() end
            end
            local physics=row.physics or C.PreparePhysics(row.triangles,nil,check)
            putVector(f,physics.low) putVector(f,physics.high) f:WriteLong(#physics.vertices)
            for i,v in ipairs(physics.vertices) do putVector(f,v.pos) if i%128==0 then check() end end
            check()
        end
    end)
end
function C.LoadRender(wall,checkpoint)
    -- Cached render normals are immutable. Key their exact serialized bytes so
    -- repeated faces avoid float decoding and native Vector allocations without
    -- rounding distinct normals together. Bound the per-load dictionary.
    local normals={} local normalCount=0
    local function cachedNormal(f)
        local at=f.at local key=f:Read(12) local normal=normals[key]
        if normal then return normal end
        f.at=at normal=vector(f)
        if normalCount<4096 then normals[key]=normal normalCount=normalCount+1 end
        return normal
    end
    local all,allowed=chunks(wall.FieldVolume)
    return decode(wall,C.RenderKind(),checkpoint,function(f,check)
        assert(count(f,4096)==#all,'Render layout changed')
        local result={} local total=0
        for _=1,#all do
            local key=stringRead(f) assert(allowed[key] and not result[key],'Invalid render chunk')
            local batches={}
            for _=1,count(f,1024) do
                local id=count(f,#wall.WallMaterialNames) assert(id>0,'Invalid material')
                local baked=count(f,1)==1 local model=stringRead(f)
                if baked then assert(model:match('^%*%d+$'),'Invalid lightmap model') end
                local n=count(f,3000000) assert(n%3==0,'Invalid vertex count') total=total+n assert(total<=12000000,'Render cache too large')
                local vertices={}
                for i=1,n do
                    local v={pos=vector(f),normal=cachedNormal(f),u=number(f),v=number(f)}
                    if baked then v.u1=number(f) v.v1=number(f) end
                    v.color=Color(f:ReadByte(),f:ReadByte(),f:ReadByte(),255)
                    vertices[i]=v if i%64==0 then check() end
                end
                batches[#batches+1]={id=id,baked=baked,model=model,vertices=vertices} check()
            end
            result[key]=batches check()
        end
        return result
    end)
end
function C.SaveRender(wall,checkpoint,bundles)
    if wall.FieldVolume.revision~=0 then return false end
    local all=chunks(wall.FieldVolume)
    return encode(wall,C.RenderKind(),checkpoint,function(f,check)
        f:WriteLong(#all)
        for _,chunk in ipairs(all) do
            local ent=wall.FieldChunks[chunk.key]
            local bundle=assert(bundles and bundles[chunk.key] or ent and ent.FieldRenderBundle,'Incomplete initial render buffers')
            stringWrite(f,chunk.key) f:WriteLong(#bundle.batches)
            for _,b in ipairs(bundle.batches) do
                f:WriteLong(b.id) f:WriteLong(b.baked and 1 or 0) stringWrite(f,b.model or '') f:WriteLong(#b.vertices)
                for i,v in ipairs(b.vertices) do
                    putVector(f,v.pos) putVector(f,v.normal) f:WriteFloat(v.u) f:WriteFloat(v.v)
                    if b.baked then f:WriteFloat(v.u1) f:WriteFloat(v.v1) end
                    local c=v.color or color_white f:WriteByte(c.r) f:WriteByte(c.g) f:WriteByte(c.b)
                    if i%64==0 then check() end
                end
                check()
            end
            check()
        end
    end)
end
return C
