if SERVER then
    AddCSLuaFile()
    AddCSLuaFile('rf_geomod/physgun.lua')
    AddCSLuaFile('rf_geomod/effect_profiles.lua')
    AddCSLuaFile('rf_geomod/decals.lua')
    AddCSLuaFile('rf_geomod/effects_client.lua')
end
include('rf_geomod/physgun.lua')
include('rf_geomod/effect_profiles.lua')
RFGeoMod=RFGeoMod or {}
RFGeoMod.DefaultSurfaceMaterial='brick/brickwall003a'
RFGeoMod.DefaultCutMaterial='concrete/concretewall036a'
include('rf_geomod/decals.lua')
local fieldFiles={'geometry','bsp','surface','field','field_queries','field_groups','field_sources','field_cache'}
for _,name in ipairs(fieldFiles) do
    local path='rf_geomod/'..name..'.lua'
    if SERVER then AddCSLuaFile(path) end
    include(path)
end
if SERVER then
    AddCSLuaFile('rf_geomod/field_runtime.lua') AddCSLuaFile('rf_geomod/field_render.lua')
    AddCSLuaFile('rf_geomod/lightmaps.lua') AddCSLuaFile('rf_geomod/scorch.lua')
else
    include('rf_geomod/lightmaps.lua') include('rf_geomod/scorch.lua') include('rf_geomod/field_render.lua')
end
include('rf_geomod/field_runtime.lua')
-- RF-137: GeoMod surfaces receive player, NPC and prop shadows.
if SERVER then AddCSLuaFile('rf_geomod/shadows.lua') end
include('rf_geomod/shadows.lua')
-- Toolgun GeoMod walls (RF-071): Sandbox limit and cleanup group. Detached
-- chunks join their owner's cleanup but not the placement limit.
if cleanup and cleanup.Register then cleanup.Register('rf_geomod_walls') end
if SERVER then CreateConVar('sbox_maxrf_geomod_walls','10',bit.bor(FCVAR_ARCHIVE,FCVAR_NOTIFY),'Maximum GeoMod walls per player.') end
if CLIENT then
    language.Add('Cleanup_rf_geomod_walls','GeoMod Walls')
    language.Add('Cleaned_rf_geomod_walls','Cleaned up all GeoMod walls')
    language.Add('SBoxLimit_rf_geomod_walls',"You've hit the GeoMod wall limit!")
    language.Add('Undone_rf_geomod_wall','Undone GeoMod wall')
end
if SERVER then
    include('rf_geomod/effects.lua')
    hook.Add('PlayerInitialSpawn','rf_geomod_join_state',function(ply)
        timer.Simple(3,function()
            if not IsValid(ply) then return end
            for _,wall in ipairs(ents.FindByClass('rf_geomod_dynamic')) do wall:SendState(ply) end
        end)
    end)
    local function authorized(ply) return not IsValid(ply) or ply:IsAdmin() end
    concommand.Add('rf_geomod_reset',function(ply)
        if not authorized(ply) then return end
        RFGeoMod.Static.Reset()
        for _,wall in ipairs(ents.FindByClass('rf_geomod_dynamic')) do wall:ResetWall() end
    end)
    concommand.Add('rf_geomod_blast',function(ply)
        if not IsValid(ply) or not authorized(ply) then return end
        local trace=ply:GetEyeTrace()
        if IsValid(trace.Entity) and IsValid(trace.Entity.GeoModProxy) then trace.Entity=trace.Entity.GeoModProxy end
        local wall=RFGeoMod.WallFor(trace.Entity)
        if IsValid(wall) then
            wall:CarveAt(trace.HitPos,trace.HitNormal,RFGeoMod.BlastRadius())
        end
    end)
else
    include('rf_geomod/effects_client.lua')
end
