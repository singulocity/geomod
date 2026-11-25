-- Client-side BSP surface lightmaps. Preserve the compiled RGBExp32 light,
-- including values above white, in a linear half-float VTF atlas. Rendering
-- uses LightmappedGeneric with a second UV channel, just like map brushwork.
RFGeoMod=RFGeoMod or {}
local cache={}
local function le(n,bytes)
    local s={} for i=1,bytes do s[i]=string.char(n%256) n=math.floor(n/256) end
    return table.concat(s)
end
local function half(x)
    if x<=0 then return '\0\0' end
    x=math.min(x,65504)
    local exponent=math.floor(math.log(x)/math.log(2))
    local bits
    if exponent < -14 then bits=math.floor(x*2^24+.5)
    else bits=(exponent+15)*1024+math.floor((x/2^exponent-1)*1024+.5) end
    return le(bits,2)
end
local function power2(n) local p=1 while p<n do p=p*2 end return p end

function RFGeoMod.ReadLightmaps(model)
    if not CLIENT then return end
    local key=game.GetMap()..':'..model
    if cache[key]~=nil then return cache[key] or nil end
    local index=tonumber(tostring(model):match('^%*(%d+)$'))
    if not index then return end
    local f=file.Open('maps/'..game.GetMap()..'.bsp','rb','GAME')
    if not f then return end
    local ok,result=xpcall(function()
        if f:Read(4)~='VBSP' or f:ReadLong()~=20 then error('Unsupported lightmap BSP') end
        local lumps={}
        for i=0,63 do lumps[i]={offset=f:ReadLong(),size=f:ReadLong(),version=f:ReadLong(),compressed=f:ReadLong()} end
        -- Choose the same lighting set the engine renders. HDR-only and
        -- non-HDR maps fall back to whichever set is available.
        local hdr=GetConVar('mat_hdr_level'):GetInt()>0 and lumps[53].size>0
        local faceLump,lightLump=hdr and 58 or 7,hdr and 53 or 8
        if lumps[lightLump].size==0 then faceLump,lightLump=58,53 end
        if lumps[lightLump].size==0 then return nil end
        local function rec(l,i,stride)
            local p=lumps[l]
            if p.compressed~=0 or i<0 or (i+1)*stride>p.size then error('Invalid lightmap record '..l) end
            f:Seek(p.offset+i*stride)
        end
        local function vec() return Vector(f:ReadFloat(),f:ReadFloat(),f:ReadFloat()) end
        local function ushort() local v=f:ReadShort() return v<0 and v+65536 or v end
        rec(14,index,48) f:Seek(f:Tell()+40)
        local first,count=f:ReadLong(),f:ReadLong()
        local faces={} local x,y,row=1,1,0 local width=512
        for i=first,first+count-1 do
            rec(faceLump,i,56)
            local plane=ushort() f:ReadByte() f:ReadByte()
            local firstEdge=f:ReadLong() local edges=ushort() local tex=f:ReadShort()
            f:ReadShort() f:ReadShort()
            local styles={f:ReadByte(),f:ReadByte(),f:ReadByte(),f:ReadByte()}
            local offset=f:ReadLong() f:ReadFloat()
            local smin,tmin=f:ReadLong(),f:ReadLong()
            local w,h=f:ReadLong()+1,f:ReadLong()+1
            -- Style 0 is static room lighting. Animated styles cannot be baked
            -- into this atlas, so those faces retain the sampled fallback.
            if offset>=0 and styles[1]==0 and styles[2]==255 and w>0 and h>0 then
                if w+2>width then error('Surface lightmap wider than atlas') end
                if x+w+1>width then x,y,row=1,y+row,0 end
                rec(1,plane,20) local normal,d=vec(),f:ReadFloat()
                rec(6,tex,72) f:Seek(f:Tell()+32)
                local u,uo=vec(),f:ReadFloat() local v,vo=vec(),f:ReadFloat()
                local polygon={}
                for j=firstEdge,firstEdge+edges-1 do
                    rec(13,j,4) local edge=f:ReadLong()
                    rec(12,math.abs(edge),4) local a,b=ushort(),ushort()
                    rec(3,edge>=0 and a or b,12) polygon[#polygon+1]=vec()
                end
                local bytes=w*h*4
                if offset+bytes>lumps[lightLump].size then error('Truncated surface lightmap') end
                f:Seek(lumps[lightLump].offset+offset) local pixels=f:Read(bytes)
                faces[#faces+1]={id=i,normal=normal,d=d,texinfo=tex,polygon=polygon,
                    u=u,v=v,uo=uo,vo=vo,smin=smin,tmin=tmin,w=w,h=h,x=x,y=y,pixels=pixels}
                x=x+w+2 row=math.max(row,h+2)
            end
        end
        if #faces==0 then return nil end
        local height=power2(y+row)
        if height>4096 then error('Lightmap atlas exceeds size limit') end
        local rows={} local black=string.rep('\0',8)
        for iy=0,height-1 do rows[iy+1]=string.rep(black,width) end
        local converted={}
        local function encoded(value)
            if converted[value] then return converted[value] end
            local linear=value
            if not hdr then
                -- SDR's byte lookup applies gamma and 2x overbright. The
                -- engine then reads that byte texture through an sRGB sampler;
                -- float textures need that same sRGB decoding explicitly.
                local byte=math.Clamp(math.floor(math.min(value,4095/1024)^(1/2.2)*127.5+.5),0,255)
                local srgb=byte/255
                linear=srgb<=.04045 and srgb/12.92 or ((srgb+.055)/1.055)^2.4
            end
            local result=half(linear) converted[value]=result return result
        end
        for _,face in ipairs(faces) do
            for iy=-1,face.h do
                local pixels={}
                for ix=-1,face.w do
                    local at=(math.Clamp(iy,0,face.h-1)*face.w+math.Clamp(ix,0,face.w-1))*4+1
                    local r,g,b,e=face.pixels:byte(at,at+3) if e>127 then e=e-256 end
                    local gain=2^e/255
                    pixels[#pixels+1]=encoded(r*gain)..encoded(g*gain)..encoded(b*gain)..half(1)
                end
                local rowIndex=face.y+iy+1 local left=(face.x-1)*8
                local old=rows[rowIndex] local bytes=table.concat(pixels)
                rows[rowIndex]=old:sub(1,left)..bytes..old:sub(left+#bytes+1)
            end
            face.pixels=nil
        end
        -- VTF 7.2, one mip, RGBA16161616F (24), no sRGB flag. There is no
        -- low-resolution image; Source reads the linear atlas after 80 bytes.
        local header='VTF\0'..le(7,4)..le(2,4)..le(80,4)..le(width,2)..le(height,2)
            ..le(0x30C,4)..le(1,2)..le(0,2)..string.rep('\0',20)
            ..le(0x3F800000,4)..le(24,4)..le(1,1)..le(0xFFFFFFFF,4)..le(0,1)..le(0,1)..le(1,2)
        header=header..string.rep('\0',80-#header)
        local data=header..table.concat(rows)
        local path='rf_geomod_lightmaps/'..game.GetMap()..'_'..index..'_'..util.CRC(data)..'.vtf'
        file.CreateDir('rf_geomod_lightmaps')
        local old=file.Find('rf_geomod_lightmaps/'..game.GetMap()..'_'..index..'_*.vtf','DATA')
        for _,name in ipairs(old) do
            if 'rf_geomod_lightmaps/'..name~=path then file.Delete('rf_geomod_lightmaps/'..name) end
        end
        if not file.Exists(path,'DATA') then file.Write(path,data) end
        local mat=CreateMaterial('rf_geomod_atlas11_'..util.CRC(path),'UnlitGeneric',{
            ['$basetexture']='../data/'..path:gsub('%.vtf$','')})
        local texture=mat:GetTexture('$basetexture')
        if mat:IsError() or not texture or texture:IsError() then error('Cannot load generated lightmap atlas') end
        return {faces=faces,texture=texture,width=width,height=height,path=path,hdr=hdr}
    end,debug.traceback)
    f:Close()
    if not ok then ErrorNoHalt('[GeoMod lightmaps] '..tostring(result)..'\n') result=nil end
    cache[key]=result or false
    return result
end

-- Partition rather than just intersect: a field triangle can extend beyond the
-- compiler's lightmap polygons. Keep those uncovered regions with vertex
-- lighting, without drawing the original triangle over its baked fragments.
local function splitPolygon(polygon,n,d)
    local inside,outside={},{}
    local positive,negative=false,false
    for _,p in ipairs(polygon) do
        local distance=n:Dot(p)-d
        if distance>.0001 then positive=true elseif distance<-.0001 then negative=true end
    end
    if not negative then return polygon,{} end
    if not positive then return {},polygon end
    for i,p in ipairs(polygon) do
        local q=polygon[i%#polygon+1] local dp,dq=n:Dot(p)-d,n:Dot(q)-d
        if dp>=0 then inside[#inside+1]=p end
        if dp<=0 then outside[#outside+1]=p end
        if dp*dq<0 then
            local hit=p+(q-p)*(dp/(dp-dq))
            inside[#inside+1]=hit outside[#outside+1]=hit
        end
    end
    return inside,outside
end
function RFGeoMod.LightmapFragments(face,atlas)
    if not atlas or not face.uv or face.mat==1 then return {face} end
    local fragments,pending={},{face.points}
    local function fragment(polygon,lm)
        return {points=polygon,normal=face.normal,mat=face.mat,uv=face.uv,nodraw=face.nodraw,lightmap=lm}
    end
    for _,lm in ipairs(atlas.faces) do
        if #pending==0 then break end
        if math.abs(lm.normal:Dot(face.normal))>.9999 and math.abs(lm.normal:Dot(face.points[1])-lm.d)<.03 then
            if not lm.clipPlanes then
                lm.clipPlanes={}
                local center=Vector() for _,p in ipairs(lm.polygon) do center=center+p end center=center/#lm.polygon
                for i,a in ipairs(lm.polygon) do
                    local b=lm.polygon[i%#lm.polygon+1]
                    local n=(b-a):Cross(lm.normal):GetNormalized() local d=n:Dot(a)
                    if n:Dot(center)-d<0 then n=-n d=-d end
                    if n:LengthSqr()>0 then lm.clipPlanes[#lm.clipPlanes+1]={n=n,d=d} end
                end
            end
            local remaining={}
            for _,polygon in ipairs(pending) do
                local original=polygon
                local overlap=polygon
                for _,plane in ipairs(lm.clipPlanes) do
                    overlap=splitPolygon(overlap,plane.n,plane.d)
                    if #overlap<3 then break end
                end
                if #overlap<3 then
                    remaining[#remaining+1]=original
                else
                    for _,plane in ipairs(lm.clipPlanes) do
                        local outside
                        polygon,outside=splitPolygon(polygon,plane.n,plane.d)
                        if #outside>=3 then remaining[#remaining+1]=outside end
                        if #polygon<3 then break end
                    end
                    fragments[#fragments+1]=fragment(overlap,lm)
                end
            end
            pending=remaining
        end
    end
    for _,polygon in ipairs(pending) do fragments[#fragments+1]=fragment(polygon) end
    return fragments
end
