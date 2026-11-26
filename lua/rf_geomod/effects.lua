-- Successful-cut effects and bounded, authoritative temporary fragments.
RFGeoMod=RFGeoMod or {}
local G=RFGeoMod
G.DebrisPool=G.DebrisPool or {}
G.EffectsEnabled=CreateConVar('rf_geomod_effects','1',bit.bor(FCVAR_ARCHIVE,FCVAR_REPLICATED),'GeoMod dust, chips and temporary rocks.')
G.DebrisMaximum=CreateConVar('rf_geomod_debris_max','80',FCVAR_ARCHIVE,'Maximum live GeoMod fragments; zero disables rocks.',0,128)
G.DebrisDamage=CreateConVar('rf_geomod_debris_damage','1',FCVAR_ARCHIVE,'Airborne GeoMod fragment damage multiplier.',0,10)
util.AddNetworkString('rf_geomod_effect')

local function event(kind,position,normal,radius,profile,direction)
    net.Start('rf_geomod_effect') net.WriteBool(kind=='drill')
    net.WriteVector(position) net.WriteNormal(normal) net.WriteFloat(radius)
    net.WriteString(profile)
    net.WriteNormal(direction or normal)
    net.SendPVS(position)
end

function G.EmitDrillContact(wall,position,normal,radius)
    if not G.EffectsEnabled:GetBool() or not G.IsWall(wall) then return false end
    event('drill',position,normal:GetNormalized(),radius,G.WallEffectProfile(wall))
    return true
end

function G.SpawnFragment(position,velocity,radius,material,seed,profile)
    local maximum=G.DebrisMaximum:GetInt()
    if not G.EffectsEnabled:GetBool() or maximum<=0 then return end
    for i=#G.DebrisPool,1,-1 do if not IsValid(G.DebrisPool[i]) then table.remove(G.DebrisPool,i) end end
    while #G.DebrisPool>=maximum do
        local oldest=table.remove(G.DebrisPool,1)
        if IsValid(oldest) then oldest:Remove() end
    end
    local rock=ents.Create('rf_geomod_debris')
    if not IsValid(rock) then return end
    rock:SetPos(position) rock:SetRockRadius(math.Clamp(radius,2,10))
    rock:SetRockSeed(seed or math.random(1,65535))
    rock.EffectProfile=profile or G.MapEffectProfile()
    rock.ImpactMaterial=material
    local override=G.GetEffectProfile(rock.EffectProfile).rock_material
    if isstring(override) and file.Exists('materials/'..override..'.vmt','GAME') then material=override end
    rock:SetRockMaterial(material or 'concrete/concretewall036a')
    rock:Spawn() rock:Activate()
    local phys=rock:GetPhysicsObject()
    if not IsValid(phys) then rock:Remove() return end
    phys:SetVelocity(velocity) phys:AddAngleVelocity(VectorRand()*math.Rand(180,360))
    G.DebrisPool[#G.DebrisPool+1]=rock
    return rock
end

local function debrisFaces(pieces,normal,checkpoint)
    local faces,area={},0
    for _,piece in ipairs(pieces or {}) do
        for _,face in ipairs(piece.faces) do
            local facing=face.normal:Dot(normal)
            if facing>.05 then
                local points=face.points
                local a=points[1]
                for i=2,#points-1 do
                    local b,c=points[i],points[i+1]
                    local weight=(b-a):Cross(c-a):Length()*facing
                    if weight>.001 then
                        area=area+weight
                        faces[#faces+1]={a=a,b=b,c=c,area=area}
                    end
                end
            end
        end
        if checkpoint then checkpoint() end
    end
    return faces,area
end

function G.EmitRockFragments(wall,position,normal,radius,removedVolume,checkpoint,direction,pieces,checkOpening,ejected)
    if not G.EffectsEnabled:GetBool() then return end
    local count=math.Clamp(math.ceil(2*(removedVolume/4000)^(2/3)),1,24)
    local maxSize=math.Clamp((removedVolume/count)^(1/3)*.45,2,10)
    local profile=G.WallEffectProfile(wall)
    local transform,localNormal=nil,normal
    if pieces and wall:GetClass()=='rf_geomod_dynamic' then
        local origin,angles=wall:GetPos(),wall:GetAngles()
        transform=function(point) return LocalToWorld(point,angle_zero,origin,angles) end
        localNormal=wall:WorldToLocal(origin+normal)
    end
    local faces,area=debrisFaces(pieces,localNormal,checkpoint)
    local forward,farCorner
    if checkOpening and direction:Dot(normal)>.05 then
        forward=-direction
        local low,high=wall:WorldSpaceAABB()
        farCorner=Vector(forward.x>=0 and high.x or low.x,forward.y>=0 and high.y or low.y,
            forward.z>=0 and high.z or low.z)
    end
    local tangent=normal:Cross(math.abs(normal.z)<0.9 and vector_up or Vector(1,0,0)):GetNormalized()
    local other=normal:Cross(tangent)
    local faceIndex=1
    for i=1,count do
        local size=2+(maxSize-2)*math.Rand(0,1)^3
        local sampleArea=area*(i-.5)/count
        while faces[faceIndex] and faces[faceIndex].area<sampleArea do faceIndex=faceIndex+1 end
        local face=faces[faceIndex]
        for _=1,3 do
            local point
            if face then
                -- One stratified area band per rock; use actual triangles so
                -- concave cuts and holes don't emit from empty space.
                local s,t=math.sqrt(math.Rand(0,1)),math.Rand(0,1)
                point=face.a*(1-s)+face.b*(s*(1-t))+face.c*(s*t)
                if transform then point=transform(point) end
            else
                point=position+tangent*math.Rand(-radius*.35,radius*.35)+other*math.Rand(-radius*.35,radius*.35)
            end
            local pos=point+normal*(size*2+4)
            local extent=Vector(size,size,size)
            local clear=util.TraceHull({start=pos,endpos=pos,mins=-extent,maxs=extent,mask=MASK_SOLID})
            if not clear.StartSolid then
                local velocity
                if direction==false then
                    local z=math.Rand(-1,1)
                    local angle=math.Rand(0,math.pi*2)
                    local horizontal=math.sqrt(1-z*z)
                    velocity=Vector(horizontal*math.cos(angle),horizontal*math.sin(angle),z)*math.Rand(100,280)
                elseif direction then
                    local axis=direction
                    if forward and i%2==0 then
                        local distance=(farCorner-pos):Dot(forward)+size*2
                        if distance>0 then
                            -- A cut's loose offcuts don't close the opening in the wall.
                            local exit=util.TraceHull({start=pos,endpos=pos+forward*distance,
                                mins=-extent,maxs=extent,mask=MASK_SOLID,filter=ejected})
                            if not exit.Hit then axis=forward end
                        end
                    end
                    local scatter=VectorRand()*65+vector_up*math.Rand(20,90)
                    -- Keep the checked forward trajectory clear of the hole's edges.
                    if axis==forward then scatter=vector_origin end
                    velocity=axis*math.Rand(100,280)+scatter-axis*scatter:Dot(axis)
                else
                    velocity=VectorRand()*60+vector_up*40
                end
                G.SpawnFragment(pos,velocity,size,wall.CutMaterialName,nil,profile)
                break
            end
        end
        if checkpoint then checkpoint() end
    end
end

function G.EmitDestruction(wall,position,normal,radius,removedVolume,checkpoint,direction,pieces,rockMotion,ejected)
    if not G.EffectsEnabled:GetBool() then return end
    normal=normal:GetNormalized()
    direction=G.DebrisDirection(direction,normal)
    event('cut',position,normal,radius,G.WallEffectProfile(wall),direction)
    local incoming=isvector(rockMotion) and rockMotion
    local rockDirection=incoming and -incoming or direction
    if rockMotion=='scatter' then rockDirection=false end
    G.EmitRockFragments(wall,position,normal,radius,removedVolume,checkpoint,rockDirection,pieces,
        incoming or rockMotion=='blast',ejected)
end

hook.Add('PostCleanupMap','rf_geomod_fragment_cleanup',function() G.DebrisPool={} end)
cvars.AddChangeCallback('rf_geomod_effects',function(_,_,value)
    if tonumber(value)==0 then
        for _,rock in ipairs(G.DebrisPool) do if IsValid(rock) then rock:Remove() end end
        G.DebrisPool={}
    end
end,'rf_geomod_fragment_cleanup')
