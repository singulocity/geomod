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

function G.EmitDestruction(wall,position,normal,radius,removedVolume,checkpoint,direction)
    if not G.EffectsEnabled:GetBool() then return end
    normal=normal:GetNormalized()
    direction=G.DebrisDirection(direction,normal)
    local profile=G.WallEffectProfile(wall)
    event('cut',position,normal,radius,profile,direction)
    local count=math.Clamp(math.ceil(removedVolume/64000*6),4,18)
    local tangent=normal:Cross(math.abs(normal.z)<0.9 and vector_up or Vector(1,0,0)):GetNormalized()
    local other=normal:Cross(tangent)
    for i=1,count do
        local size=(0.05+math.Rand(0,1)^3*0.2)*40
        local pos=position+normal*(size*2+4)+tangent*math.Rand(-radius*0.35,radius*0.35)+other*math.Rand(-radius*0.35,radius*0.35)
        local extent=Vector(size,size,size)
        local clear=util.TraceHull({start=pos,endpos=pos,mins=-extent,maxs=extent,mask=MASK_SOLID})
        if not clear.StartSolid then
            local scatter=VectorRand()*65+vector_up*math.Rand(20,90)
            local velocity=direction*math.Rand(100,280)+scatter-direction*scatter:Dot(direction)
            G.SpawnFragment(pos,velocity,size,wall.CutMaterialName,nil,profile)
        end
        if checkpoint then checkpoint() end
    end
end

hook.Add('PostCleanupMap','rf_geomod_fragment_cleanup',function() G.DebrisPool={} end)
cvars.AddChangeCallback('rf_geomod_effects',function(_,_,value)
    if tonumber(value)==0 then
        for _,rock in ipairs(G.DebrisPool) do if IsValid(rock) then rock:Remove() end end
        G.DebrisPool={}
    end
end,'rf_geomod_fragment_cleanup')
