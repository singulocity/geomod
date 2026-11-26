local G=RFGeoMod
local enabled=CreateConVar('rf_geomod_physics_cuts','1',FCVAR_ARCHIVE,
    'Allow fast, heavy VPhysics impacts to fracture GeoMod walls.',0,1)
local minEnergy=CreateConVar('rf_geomod_physics_min_energy','18000000',FCVAR_ARCHIVE,
    'Minimum normal impact energy in kg times squared Source units per second.',1000000,500000000)

-- Only these two bodies ignore each other. Floors, props and other walls
-- still collide normally. Never create or remove constraints in PhysicsCollide.
function G.SeparateFractureBodies(a,b)
    if not IsValid(a) or not IsValid(b) or a==b then return end
    local pair=constraint.NoCollide(a,b,0,0,true)
    if not IsValid(pair) then return end
    pair.DoNotDuplicate=true
    local checks=0
    local function release()
        if not IsValid(pair) then return end
        checks=checks+1
        if checks<8 and IsValid(a) and IsValid(b) then
            local low,high=a:WorldSpaceAABB()
            local otherLow,otherHigh=b:WorldSpaceAABB()
            if low.x<=otherHigh.x+2 and high.x>=otherLow.x-2
                and low.y<=otherHigh.y+2 and high.y>=otherLow.y-2
                and low.z<=otherHigh.z+2 and high.z>=otherLow.z-2 then
                timer.Simple(.05,release)
                return
            end
        end
        pair:Remove()
    end
    timer.Simple(.08,release)
end

function G.ContinuePropThroughCut(wall,impact)
    local prop=impact and impact.prop
    if not IsValid(prop) or CurTime()-impact.time>.25 or prop:IsPlayerHolding() then return false end
    local physics=prop:GetPhysicsObject()
    if not IsValid(physics) or physics~=impact.physics or not physics:IsMotionEnabled() then return false end
    local position=prop:GetPos()
    local low,high=prop:WorldSpaceAABB()
    local span=(high-low):Length()
    if position:DistToSqr(impact.point)>(span+32)^2 then return false end
    local direction=impact.velocity:GetNormalized()
    local perpendicular=-direction:Dot(impact.normal)
    if perpendicular<.65 then return false end
    -- The conservative world-space hull must clear the rebuilt slab. Trace
    -- only that slab; the prop still collides with everything along its path.
    local travel=math.min((span*2+32)/perpendicular,384)
    if util.TraceHull({start=position,endpos=position+direction*travel,mins=low-position,
        maxs=high-position,filter={wall},whitelist=true,ignoreworld=true,mask=MASK_SOLID}).Hit then return false end
    local speed=math.min(impact.velocity:Length()*.35,550)
    if physics:GetVelocity():Dot(direction)<speed then physics:SetVelocity(direction*speed) end
    return true
end

function G.LimitFractureRebound(ent,impact)
    if not IsValid(ent) then return end
    local physics=ent:GetPhysicsObject()
    local normal,incoming=impact.landing,impact.velocity
    local slideLimit=math.max(120,(incoming-normal*incoming:Dot(normal)):Length()+64)
    -- Include the tick when temporary collision pairs can be restored.
    local untilTime=CurTime()+.55
    local function settle()
        if not IsValid(ent) or not IsValid(physics) or physics~=ent:GetPhysicsObject()
            or not physics:IsMotionEnabled() or ent:IsPlayerHolding() then return end
        local velocity=physics:GetVelocity()
        local away=velocity:Dot(normal)
        local slide=velocity-normal*away
        -- The rebuilt contact must not add a large kick. Keep downward
        -- motion, existing slide with some collision response, and spin.
        if away>48 or slide:LengthSqr()>slideLimit^2 then
            physics:SetVelocityInstantaneous(slide:GetNormalized()*math.min(slide:Length(),slideLimit)
                +normal*math.min(away,48))
        end
        if CurTime()<untilTime then timer.Simple(engine.TickInterval(),settle) end
    end
    settle()
end

local function weakenedAt(wall,point)
    local cuts=wall.Cuts or {}
    if wall:GetClass()=='rf_geomod_dynamic' then point=wall:WorldToLocal(point) end
    for i=#cuts,math.max(1,#cuts-15),-1 do
        local op=cuts[i]
        if G.IsContactFracture(op) and point:DistToSqr(op.center)<(op.radius+18)^2 then return true end
    end
end

function G.HandlePhysicsImpact(striker,data)
    if not enabled:GetBool() or striker.GeoModImpactEjected then return end
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
    if not IsValid(wall) or wall.GeoModImpactEjected or (wall==striker and not selfImpact) then return end
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
    local impact={}
    if selfImpact and landing then
        impact.landing=outward
        impact.velocity=data.OurOldVelocity
    elseif wall:GetClass()=='rf_geomod_dynamic' and striker:GetClass()=='prop_physics' then
        impact={prop=striker,physics=physics,velocity=data.OurOldVelocity,point=data.HitPos,normal=outward,time=now}
    end
    if G.CutContact(wall,data.HitPos,outward,radius,source,impact) then
        striker.GeoModNextStrike=now+.1
        wall.GeoModNextImpact=now+.14
    end
end

hook.Add('PhysgunDrop','rf_geomod_rearm_impact',function(_,ent)
    if IsValid(ent) then ent.GeoModImpactEjected=nil end
end)

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
