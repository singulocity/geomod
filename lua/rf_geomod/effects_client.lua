RFGeoMod=RFGeoMod or {}
local G=RFGeoMod
local particles=CreateClientConVar('rf_geomod_particles','1',true,false,'Draw cosmetic GeoMod dust/chips; physical rocks remain visible.')
local resolved={}
local function smokeMaterials(paths)
    if not istable(paths) or #paths==0 then return end
    local frames={}
    for i,path in ipairs(paths) do
        local material=G.EffectMaterial(path)
        if not material then return end
        frames[i]=material
    end
    return frames
end

function G.GetParticleAppearance(id)
    local profile=G.GetEffectProfile(id)
    if resolved[profile] then return resolved[profile] end
    local stock=G.GetEffectProfile('stock')
    local appearance={
        dust=smokeMaterials(profile.dust) or smokeMaterials(stock.dust) or {},
        drill=G.EffectMaterial(profile.drill) or G.EffectMaterial(stock.drill),
        chip=G.EffectMaterial(profile.chip) or G.EffectMaterial(stock.chip),
        spark=G.EffectMaterial(profile.spark) or G.EffectMaterial(stock.spark),
        bubble=G.EffectMaterial(profile.bubble) or G.EffectMaterial(stock.bubble),
    }
    resolved[profile]=appearance
    return appearance
end

local function make(emitter,material,position,velocity,life,size,growth,alpha,color,gravity)
    if not material then return end
    local p=emitter:Add(material,position)
    if not p then return end
    p:SetVelocity(velocity) p:SetDieTime(life)
    p:SetStartSize(size) p:SetEndSize(math.max(0,size+growth*life))
    p:SetStartAlpha(alpha) p:SetEndAlpha(0)
    p:SetColor(color.r,color.g,color.b) p:SetRoll(math.Rand(-math.pi,math.pi))
    p:SetRollDelta(math.Rand(-0.4,0.4)) p:SetGravity(gravity)
    p:SetLighting(true)
    return p
end

function G.PlayDestructionParticles(drill,position,normal,radius,profile,direction)
    if not particles:GetBool() then return 0 end
    local emitter=ParticleEmitter(position)
    if not emitter then return 0 end
    local appearance=G.GetParticleAppearance(profile)
    local smoke=appearance.dust
    local emitted=0
    local wet=bit.band(util.PointContents(position),CONTENTS_WATER)~=0
    local gravity=physenv.GetGravity()
    direction=direction or normal
    -- Keep slow dust in front of the surviving surface. A spherical random
    -- offset can bury half the puffs inside the wall for their entire life.
    local function dustOrigin()
        local jitter=VectorRand()*radius*0.15
        jitter=jitter-normal*jitter:Dot(normal)
        return position+normal*(8+math.min(radius*0.15,16))+jitter
    end
    if not wet then
        for i=1,(drill and 2 or 5) do
            local size=drill and math.Rand(16,28) or math.Rand(30,50)
            local life=drill and math.Rand(0.55,0.9) or math.Rand(1,2)
            local p=make(emitter,drill and appearance.drill or smoke[1],dustOrigin(),
                normal*math.Rand(drill and 24 or 4,drill and 48 or 12)+VectorRand()*8,
                life,size,drill and 35 or 30,drill and 64 or 155,color_white,gravity*(drill and 0.1 or 0.05))
            if p then
                p:SetAirResistance(12)
                if not drill and #smoke>1 then
                    p:SetNextThink(CurTime())
                    p:SetThinkFunction(function(particle)
                        local frame=math.min(#smoke,1+math.floor(particle:GetLifeTime()*15))
                        particle:SetMaterial(smoke[frame]) particle:SetNextThink(CurTime()+1/30)
                    end)
                end
                emitted=emitted+1
            end
        end
    else
        for i=1,8 do
            local p=make(emitter,appearance.bubble,position+VectorRand()*radius*0.2,normal*30+VectorRand()*20,
                math.Rand(0.5,1.2),math.Rand(1,3),1,140,color_white,Vector(0,0,45))
            if p then emitted=emitted+1 end
        end
    end
    local chips=drill and 3 or 25
    for i=1,chips do
        local scatter=VectorRand()*30
        local p=make(emitter,appearance.chip,position+normal*3+VectorRand()*radius*0.1,
            direction*math.Rand(drill and 20 or 80,drill and 160 or 400)+scatter-direction*scatter:Dot(direction),
            drill and 0.8 or math.Rand(1,3),math.Rand(2,4),0,drill and 192 or 255,
            drill and Color(64,128,170) or Color(128,128,128),gravity)
        if p then p:SetCollide(true) p:SetBounce(0.25) emitted=emitted+1 end
    end
    if drill and not wet then
        for i=1,4 do
            local p=make(emitter,appearance.spark,position+normal*3,normal*math.Rand(40,80)+VectorRand()*45,
                0.8,math.Rand(1.2,2.4),0,255,color_white,gravity)
            if p then p:SetCollide(true) p:SetBounce(0.15) p:SetLighting(false) emitted=emitted+1 end
        end
    end
    emitter:Finish()
    return emitted
end

net.Receive('rf_geomod_effect',function()
    G.PlayDestructionParticles(net.ReadBool(),net.ReadVector(),net.ReadNormal(),net.ReadFloat(),net.ReadString(),
        net.ReadNormal())
end)
