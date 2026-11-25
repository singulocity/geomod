if RFMapProtection then return end
RFMapProtection = {}

-- A missing key must protect existing compiled maps as well as new FGD entities.
-- The toolgun is intentionally not restricted; only physgun pickup is.
function RFMapProtection.Apply(ent,config)
    local physgun=config.disable_physgun~='0'
    ent.PhysgunDisabled=physgun
    ent:SetNWBool('rf_map_disable_physgun',physgun)
end

hook.Add('PhysgunPickup','rf_map_protection',function(_,ent)
    if IsValid(ent) and ent:GetNWBool('rf_map_disable_physgun',false) then return false end
end)

if SERVER then
    -- Lambda's autonomous physgun selection bypasses Sandbox's hooks and
    -- fields. Preserve its ownership rules, adding only our entity restriction.
    hook.Add('LambdaOnInitialize','rf_map_protection',function(bot)
        local original=bot.HasPermissionToEdit
        if not isfunction(original) or bot.RFMapProtectionWrapped then return end
        bot.RFMapProtectionWrapped=true
        bot.HasPermissionToEdit=function(self,ent,...)
            if IsValid(ent) and self:GetWeaponName()=='physgun' and ent:GetNWBool('rf_map_disable_physgun',false) then return false end
            return original(self,ent,...)
        end
    end)
end
