local G=RFGeoMod
local enabled=CreateConVar('rf_geomod_physics_cuts','1',FCVAR_ARCHIVE,
    'Allow fast, heavy VPhysics impacts to fracture GeoMod walls.',0,1)
local minEnergy=CreateConVar('rf_geomod_physics_min_energy','18000000',FCVAR_ARCHIVE,
    'Minimum normal impact energy in kg times squared Source units per second.',1000000,500000000)

local function weakenedAt(wall,point)
    local cuts=wall.Cuts or {}
    if wall:GetClass()=='rf_geomod_dynamic' then point=wall:WorldToLocal(point) end
    for i=#cuts,math.max(1,#cuts-15),-1 do
        local op=cuts[i]
        if G.IsContactFracture(op) and point:DistToSqr(op.center)<(op.radius+18)^2 then return true end
    end
end

function G.HandlePhysicsImpact(striker,data)
    if not enabled:GetBool() then return end
    local wall=G.ContactWall(data.HitEntity)
    local normal=data.HitNormal
    local approach=data.OurOldVelocity:Dot(normal)
    local outward=(approach>0 and -normal or normal):GetNormalized()
    -- An intact movable wall can fracture on a hard landing against a floor.
    -- Detached chunks can also chip against other solid objects.
    local landing=outward.z>=.5 and striker:GetClass()=='rf_geomod_dynamic'
        and (data.HitEntity==game.GetWorld() or IsValid(data.HitObject) and not data.HitObject:IsMotionEnabled())
    local selfImpact=not IsValid(wall) and (striker.IsChunk or landing)
    if selfImpact then wall=striker end
    if not IsValid(wall) or (wall==striker and not selfImpact) then return end
    local now=CurTime()
    if now<(striker.GeoModNextStrike or 0) or now<(wall.GeoModNextImpact or 0) then return end

    local physics=data.PhysObject
    if not IsValid(physics) or not physics:IsMotionEnabled() or striker:IsPlayerHolding() or wall:IsPlayerHolding() then return end
    local weakened=wall.IsChunk or weakenedAt(wall,data.HitPos)
    local mass=physics:GetMass()
    if mass<(weakened and 8 or 50) then return end
    local relative=approach-data.TheirOldVelocity:Dot(normal)
    -- Use the striker's contribution and relative closing speed. Tangential
    -- motion and a moving wall hitting a stationary prop should not carve.
    if approach*relative<=0 then return end
    local speed=math.min(math.abs(approach),math.abs(relative))
    local minimumSpeed=weakened and 125 or 225
    if selfImpact and landing and not wall.IsChunk then minimumSpeed=400 end
    if speed<minimumSpeed then return end
    local energy=.5*mass*speed*speed
    local threshold=minEnergy:GetFloat()*(wall.IsChunk and .16 or (weakened and .4 or 1))
    if energy<threshold then return end
    local radius=math.Clamp((weakened and 14 or 24)*math.sqrt(energy/threshold),
        weakened and 14 or 24,weakened and 38 or 64)*G.HardnessCraterScale(wall.Hardness)

    -- The cut API only queues work. VPhysics is rebuilt later, outside this
    -- collision callback. The cooldown also bounds multi-contact impacts.
    local source=-data.OurOldVelocity:GetNormalized()
    if selfImpact and not landing then outward,source=-outward,-source end
    if G.CutContact(wall,data.HitPos,outward,radius,source) then
        striker.GeoModNextStrike=now+.1
        wall.GeoModNextImpact=now+.14
    end
end

local function register(ent)
    if not IsValid(ent) then return end
    if ent:GetMoveType()~=MOVETYPE_VPHYSICS and not ent:IsVehicle() then return end
    local class=ent:GetClass()
    if class=='rf_geomod_dynamic' or class=='rf_geomod_debris' or class=='prop_ragdoll' then return end
    if not IsValid(ent:GetPhysicsObject()) then return end
    if ent.GeoModImpactCallback then ent:RemoveCallback('PhysicsCollide',ent.GeoModImpactCallback) end
    ent.GeoModImpactCallback=ent:AddCallback('PhysicsCollide',G.HandlePhysicsImpact)
end

hook.Add('OnEntityCreated','rf_geomod_physics_impacts',function(ent)
    -- Entity creation precedes Spawn/PhysicsInit.
    timer.Simple(0,function() register(ent) end)
end)

for _,ent in ipairs(ents.GetAll()) do register(ent) end
