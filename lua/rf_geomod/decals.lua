-- Ordinary decals (blood, bullet holes, gib splats) on GeoMod walls.
-- The wall draws its own Lua mesh, so engine decals cannot appear on it: they
-- land on the mesh entity's unused placeholder model, or on the hidden native
-- brush, which flickers through the mesh whenever it is drawn. Decals aimed at
-- a GeoMod wall are therefore painted by the wall itself, clipped to its
-- current faces like bound posters, and rebuilt after each cut.
RFGeoMod=RFGeoMod or {}
local MAX_DECALS=128 -- per wall; the oldest are dropped first, like the engine's decal limit
local BLEED_DISTANCE=172 -- Source's blood trace length behind a shot character
RFGeoMod.DecalVariants=RFGeoMod.DecalVariants or {}

-- The runtime mesh for a hit entity: the mesh itself, or the native brush its
-- proxy owns (server field or networked owner).
function RFGeoMod.DecalWall(ent)
    if RFGeoMod.WallFor then return RFGeoMod.WallFor(ent) end
    if not IsValid(ent) then return end
    if ent:GetClass()=='rf_geomod_dynamic' then return ent end
    local proxy=ent.GeoModProxy or ent:GetOwner()
    if IsValid(proxy) and proxy:GetClass()=='rf_geomod_dynamic' then return proxy end
end

-- GeoMod already draws its own scorch around blast cuts.
function RFGeoMod.RedirectsDecal(name)
    return not string.find(string.lower(name),'scorch',1,true)
end

-- In-plane axes for a decal facing along normal, turned by angle degrees.
function RFGeoMod.DecalBasis(normal,angle)
    local u=normal:Cross(Vector(0,0,1))
    if u:LengthSqr()<.01 then u=normal:Cross(Vector(1,0,0)) end
    u:Normalize()
    local v=normal:Cross(u)
    local c,s=math.cos(math.rad(angle or 0)),math.sin(math.rad(angle or 0))
    return u*c+v*s,v*c-u*s
end

local function clip(points,normal,distance)
    local output={}
    for i,a in ipairs(points) do
        local b=points[i%#points+1]
        local da,db=a:Dot(normal)-distance,b:Dot(normal)-distance
        if da<=.001 then output[#output+1]=a end
        if (da<0 and db>0) or (da>0 and db<0) then output[#output+1]=a+(b-a)*(da/(da-db)) end
    end
    return output
end

-- Pieces of the wall's faces under a decal: faces facing the decal normal and
-- lying in its plane, clipped to its rectangle. Groups hold triangle vertex
-- lists in the wall's local space.
function RFGeoMod.DecalPolygons(groups,origin,normal,u,v,width,height)
    local polygons={}
    for _,group in ipairs(groups) do
        for _,triangles in ipairs(group) do
            for i=1,#triangles-2,3 do
                local a=triangles[i]
                if a.normal:Dot(normal)>.98 and math.abs((a.pos-origin):Dot(normal))<1 then
                    local polygon={a.pos,triangles[i+1].pos,triangles[i+2].pos}
                    for _,plane in ipairs({{u,u:Dot(origin)+width/2},{-u,-u:Dot(origin)+width/2},
                        {v,v:Dot(origin)+height/2},{-v,-v:Dot(origin)+height/2}}) do
                        polygon=clip(polygon,plane[1],plane[2])
                        if #polygon<3 then break end
                    end
                    if #polygon>=3 then polygons[#polygons+1]=polygon end
                end
            end
        end
    end
    return polygons
end

-- Stock decals are "Subrect" materials: a cell of a shared atlas, sized by
-- $Size (pixels) times $decalscale. Returns nil for an ordinary material.
function RFGeoMod.ParseSubrect(text)
    if not text or not string.find(string.lower(text),'"?subrect"?%s*{') then return end
    local function field(name) return string.match(text,'"%$'..name..'"%s+"?([^"\r\n]+)"?') end
    local x,y=string.match(field('[Pp]os') or '','(%d+)%s+(%d+)')
    local w,h=string.match(field('[Ss]ize') or '','(%d+)%s+(%d+)')
    local material=field('[Mm]aterial')
    if not x or not w or not material then return end
    return {material=string.match(material,'^%s*(.-)%s*$'),x=tonumber(x),y=tonumber(y),w=tonumber(w),h=tonumber(h),
        scale=tonumber(field('[Dd]ecalscale') or '')}
end

-- Keeps at most MAX_DECALS per wall, returning any dropped decal.
function RFGeoMod.PushWallDecal(list,decal)
    list[#list+1]=decal
    if #list>MAX_DECALS then return table.remove(list,1) end
end

local function bloodDecal(ent)
    local color=ent.GetBloodColor and ent:GetBloodColor()
    if color==BLOOD_COLOR_RED then return 'Blood' end
    if color and color~=DONT_BLEED and color~=BLOOD_COLOR_MECH then return 'YellowBlood' end
end

-- Remember multi-material decals so walls can vary them like the engine does.
local engineAddDecal=RFGeoMod.EngineAddDecal or game.AddDecal
RFGeoMod.EngineAddDecal=engineAddDecal
function game.AddDecal(name,materials)
    if istable(materials) then RFGeoMod.DecalVariants[name]=table.Copy(materials) end
    return engineAddDecal(name,materials)
end

local engineDecal=RFGeoMod.EngineDecal or util.Decal
RFGeoMod.EngineDecal=engineDecal

if SERVER then
    util.AddNetworkString('rf_geomod_decal')
    local IMPACTS={[MAT_CONCRETE]='Impact.Concrete',[MAT_METAL]='Impact.Metal',[MAT_WOOD]='Impact.Wood',
        [MAT_GLASS]='Impact.Glass',[MAT_DIRT]='Impact.Sand',[MAT_SAND]='Impact.Sand',[MAT_TILE]='Impact.Concrete'}
    function RFGeoMod.SendWallDecal(wall,name,position,normal)
        net.Start('rf_geomod_decal',true)
        net.WriteEntity(wall) net.WriteString(name)
        net.WriteVector(position) net.WriteNormal(normal) net.WriteUInt(math.random(0,359),9)
        net.SendPVS(position)
    end
    local function paint(wall,name,position,normal) RFGeoMod.SendWallDecal(wall,name,position,normal) end

    -- Bullets: the hole on a GeoMod wall, and the blood a shot character
    -- sprays onto a GeoMod wall behind it.
    hook.Add('PostEntityFireBullets','rf_geomod_decals',function(shooter,data)
        local trace=data.Trace
        if not trace or not trace.Hit or trace.HitSky then return end
        local wall=RFGeoMod.DecalWall(trace.Entity)
        if wall then
            if hook.Run('RFGeoModCustomBulletDecal',data,trace) then return end
            paint(wall,IMPACTS[trace.MatType] or 'Impact.Concrete',trace.HitPos,trace.HitNormal)
            return
        end
        local blood=IsValid(trace.Entity) and bloodDecal(trace.Entity)
        if not blood then return end
        local behind=util.TraceLine({start=trace.HitPos,endpos=trace.HitPos+trace.Normal*BLEED_DISTANCE,
            filter={trace.Entity,shooter},mask=MASK_SOLID})
        wall=RFGeoMod.DecalWall(behind.Entity)
        if wall then paint(wall,blood,behind.HitPos,behind.HitNormal) end
    end)
    RFGeoMod.PaintWallDecal=paint
else
    local materials={}
    local function channel(value) return math.Round(math.Clamp(value,0,1)^(1/2.2)*255) end

    -- A drawable copy of a decal material, as rf_map_decal does for posters.
    local function decalMaterial(path)
        if materials[path]~=nil then return materials[path] end
        local rect=RFGeoMod.ParseSubrect(file.Read('materials/'..path..'.vmt','GAME'))
        local source=Material(rect and rect.material or path)
        local texture=not source:IsError() and source:GetTexture('$basetexture')
        if not texture or texture:IsError() then materials[path]=false return false end
        local modulate=string.find(string.lower(source:GetShader() or ''),'decalmodulate',1,true)~=nil
        local scale=rect and rect.scale or Material(path):GetFloat('$decalscale')
        if not scale or scale<=0 then scale=1 end
        local tw,th=texture:Width(),texture:Height()
        local cell=rect or {x=0,y=0,w=tw,h=th}
        local key=util.CRC(path..':geomod-decal-v2')
        local params={['$basetexture']=texture:GetName(),['$decal']='1',['$vertexcolor']='1',['$vertexalpha']='1'}
        if not modulate then params['$translucent']='1' end
        local info={modulate=modulate,width=cell.w*scale,height=cell.h*scale,
            -- The atlas cell, inset half a texel so filtering cannot reach a neighbour.
            u0=(cell.x+.5)/tw,du=(cell.w-1)/tw,v0=(cell.y+.5)/th,dv=(cell.h-1)/th,
            tint=source:GetVector('$color') or Vector(1,1,1),
            base=CreateMaterial('rf_geomod_decal_'..key,modulate and 'DecalModulate' or 'UnlitGeneric',params)}
        -- The flashlight lights ordinary decals; modulating ones only darken.
        if not modulate then info.lit=CreateMaterial('rf_geomod_decal_lit_'..key,'VertexLitGeneric',table.Copy(params)) end
        materials[path]=info
        return info
    end

    local function choose(name)
        local variants=RFGeoMod.DecalVariants[name]
        if variants and #variants>0 then return variants[math.random(#variants)] end
        local path=util.DecalMaterial(name)
        return path~='' and path or nil
    end

    local function destroy(decal)
        if decal.mesh then decal.mesh:Destroy() decal.mesh=nil end
        if decal.litMesh then decal.litMesh:Destroy() decal.litMesh=nil end
    end

    local function build(wall,decal)
        destroy(decal)
        local info=decal.info
        local u,v=RFGeoMod.DecalBasis(decal.normal,decal.angle)
        local polygons=RFGeoMod.DecalPolygons({RFGeoMod.RenderSurfaces(wall)},
            decal.pos,decal.normal,u,v,info.width,info.height)
        local worldNormal=(wall:LocalToWorld(decal.normal)-wall:GetPos()):GetNormalized()
        local triangles,lit={},{}
        local function vertex(p)
            local tu=info.u0+((p-decal.pos):Dot(u)/info.width+.5)*info.du
            local tv=info.v0+((p-decal.pos):Dot(v)/info.height+.5)*info.dv
            local color=Color(255,255,255,255)
            if not info.modulate then
                local at=wall:LocalToWorld(p)+worldNormal*2
                local light=render.ComputeLighting(at,worldNormal)-render.ComputeDynamicLighting(at,worldNormal)
                color=Color(channel(light.x*info.tint.x),channel(light.y*info.tint.y),channel(light.z*info.tint.z),255)
                lit[#lit+1]={pos=p,normal=decal.normal,u=tu,v=tv,color=Color(255,255,255,255)}
            end
            triangles[#triangles+1]={pos=p,normal=decal.normal,u=tu,v=tv,color=color}
        end
        for _,polygon in ipairs(polygons) do
            for i=2,#polygon-1 do vertex(polygon[1]) vertex(polygon[i]) vertex(polygon[i+1]) end
        end
        if #triangles==0 then return end
        decal.mesh=Mesh(info.base) decal.mesh:BuildFromTriangles(triangles)
        if info.lit then decal.litMesh=Mesh(info.lit) decal.litMesh:BuildFromTriangles(lit) end
    end

    function RFGeoMod.AddWallDecal(wall,name,position,normal,angle)
        if not IsValid(wall) then return end
        local path=choose(name)
        local info=path and decalMaterial(path)
        if not info then return end
        local origin=wall:WorldToLocal(position)
        local decal={name=name,path=path,info=info,pos=origin,normal=(wall:WorldToLocal(position+normal)-origin):GetNormalized(),
            angle=angle or math.random(0,359)}
        wall.RFDecals=wall.RFDecals or {}
        local dropped=RFGeoMod.PushWallDecal(wall.RFDecals,decal)
        if dropped then destroy(dropped) end
        if wall.RenderRevision then build(wall,decal) decal.revision=wall.RenderRevision end
        -- The engine's own copy may have landed on the hidden native brush;
        -- clear it now and once the shot's client effects have run.
        local fallback=wall:GetNWEntity('rf_geomod_fallback')
        if IsValid(fallback) then
            fallback:RemoveAllDecals()
            timer.Simple(0.1,function() if IsValid(fallback) then fallback:RemoveAllDecals() end end)
        end
    end

    -- Called from the wall's Draw, after its surfaces and bound posters.
    function RFGeoMod.DrawWallDecals(wall)
        local decals=wall.RFDecals
        if not decals or #decals==0 or not wall.RenderMatrix then return end
        for _,decal in ipairs(decals) do
            if decal.revision~=wall.RenderRevision then build(wall,decal) decal.revision=wall.RenderRevision end
        end
        cam.PushModelMatrix(wall.RenderMatrix)
        for _,decal in ipairs(decals) do
            if decal.mesh then render.SetMaterial(decal.info.base) decal.mesh:Draw() end
        end
        render.RenderFlashlights(function()
            for _,decal in ipairs(decals) do
                if decal.litMesh then render.SetMaterial(decal.info.lit) decal.litMesh:Draw() end
            end
        end)
        cam.PopModelMatrix()
    end

    function RFGeoMod.ClearWallDecals(wall)
        for _,decal in ipairs(wall.RFDecals or {}) do destroy(decal) end
        wall.RFDecals=nil
    end

    net.Receive('rf_geomod_decal',function()
        local wall,name=net.ReadEntity(),net.ReadString()
        local position,normal,angle=net.ReadVector(),net.ReadNormal(),net.ReadUInt(9)
        RFGeoMod.AddWallDecal(RFGeoMod.DecalWall(wall),name,position,normal,angle)
    end)
    function RFGeoMod.PaintWallDecal(wall,name,position,normal) RFGeoMod.AddWallDecal(wall,name,position,normal) end
end

-- Lua decals (gib splats, addon effects) aimed at a GeoMod wall are painted by
-- the wall instead of reaching the engine.
function util.Decal(name,start,finish,filter)
    if RFGeoMod.RedirectsDecal(name) then
        local trace=util.TraceLine({start=start,endpos=finish,filter=filter,mask=MASK_SOLID})
        local wall=trace.Hit and RFGeoMod.DecalWall(trace.Entity)
        if wall then RFGeoMod.PaintWallDecal(wall,name,trace.HitPos,trace.HitNormal) return end
    end
    return engineDecal(name,start,finish,filter)
end
