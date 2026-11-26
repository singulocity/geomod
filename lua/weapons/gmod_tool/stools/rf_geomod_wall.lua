-- RF-071: place destructible GeoMod walls that behave like physics props.
-- The wall itself is an rf_geomod_dynamic with a box source (entities/rf_geomod_dynamic).
TOOL.Category = "GeoMod"
TOOL.Name = "#tool.rf_geomod_wall.name"
TOOL.Information = {{name = "left"}, {name = "right"}}

local DEFAULTS = {
    surface_material = RFGeoMod.DefaultSurfaceMaterial,
    cut_material = RFGeoMod.DefaultCutMaterial,
    effects_profile = 'stock',
    thickness = "16",
    width = "128",
    height = "128",
    hardness = "50",
    frozen = "0",
    surface_repeat = "128",
    cut_repeat = "128",
}
TOOL.ClientConVar = DEFAULTS

local function sizes(get)
    local limits = {thickness = {2, 256}, width = {8, 1024}, height = {8, 1024}}
    local function value(name, default)
        return math.Round(math.Clamp(tonumber(get(name)) or default, limits[name][1], limits[name][2]))
    end
    return value("thickness", 16), value("width", 128), value("height", 128)
end

-- Floor: stand upright facing the player. Ceiling: hang down. Wall: lie flat
-- against it with the thickness along the surface normal.
local function placement(trace, ply, thickness, height)
    local normal = trace.HitNormal
    local toPlayer = ply:GetPos() - trace.HitPos
    toPlayer.z = 0
    local yaw = toPlayer:LengthSqr() > 1 and toPlayer:Angle().y or ply:EyeAngles().y + 180
    if normal.z > 0.7 then return trace.HitPos + Vector(0, 0, 0.1), Angle(0, yaw, 0) end
    if normal.z < -0.7 then return trace.HitPos - Vector(0, 0, height + 0.1), Angle(0, yaw, 0) end
    local flat = Vector(normal.x, normal.y, 0):GetNormalized()
    return trace.HitPos + flat * (thickness / 2 + 0.1) - Vector(0, 0, height / 2), Angle(0, flat:Angle().y, 0)
end

local function safePath(path)
    path = tostring(path or "")
    return path ~= "" and #path <= 160 and not path:find("..", 1, true)
        and path:match("^[%w_%-/%.]+$") and path or nil
end

function TOOL:LeftClick(trace)
    if not trace.Hit or trace.HitSky then return false end
    if IsValid(trace.Entity) and trace.Entity:IsPlayer() then return false end
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not ply:CheckLimit("rf_geomod_walls") then return false end
    local config = RFGeoMod.SanitizeWallConfig({
        thickness = self:GetClientNumber("thickness"), width = self:GetClientNumber("width"),
        height = self:GetClientNumber("height"), hardness = self:GetClientNumber("hardness"),
        surface_material = self:GetClientInfo("surface_material"), cut_material = self:GetClientInfo("cut_material"),
        surface_repeat = self:GetClientNumber("surface_repeat"), cut_repeat = self:GetClientNumber("cut_repeat"),
        effects_profile = self:GetClientInfo("effects_profile"),
    })
    local pos, ang = placement(trace, ply, config.thickness, config.height)
    local wall = RFGeoMod.SpawnWall(ply, pos, ang, config, nil, self:GetClientNumber("frozen") ~= 0)
    if not IsValid(wall) then return false end
    undo.Create("rf_geomod_wall")
        undo.AddEntity(wall)
        undo.SetPlayer(ply)
    undo.Finish()
    ply:AddCount("rf_geomod_walls", wall)
    ply:AddCleanup("rf_geomod_walls", wall)
    return true
end

-- Copy materials, hardness and effects from an existing GeoMod wall (map or placed).
function TOOL:RightClick(trace)
    local ent = RFGeoMod.WallFor(trace.Entity)
    if not IsValid(ent) then return false end
    if CLIENT then return true end
    local ply = self:GetOwner()
    ply:ConCommand("rf_geomod_wall_hardness " .. math.Round(ent.Hardness or 50))
    local surface = safePath(ent.BoxSource and ent.SurfaceMaterialName or (ent.WallMaterialNames or {})[1])
    local cut = safePath(ent.CutMaterialName)
    if surface then ply:ConCommand("rf_geomod_wall_surface_material " .. surface) end
    if cut then ply:ConCommand("rf_geomod_wall_cut_material " .. cut) end
    ply:ConCommand("rf_geomod_wall_effects_profile " .. RFGeoMod.WallEffectProfile(ent))
    return true
end

if SERVER then
    AddCSLuaFile("rf_geomod/material_browser.lua")
    return
end

local openMaterialBrowser = include("rf_geomod/material_browser.lua")

language.Add("tool.rf_geomod_wall.name", "GeoMod Wall")
language.Add("tool.rf_geomod_wall.desc", "Place a destructible GeoMod wall that behaves like a physics prop")
language.Add("tool.rf_geomod_wall.left", "Place a wall where the preview shows")
language.Add("tool.rf_geomod_wall.right", "Copy materials, hardness and effects from a GeoMod wall")

local previewMaterials = {}
local function previewMaterial(path, ghost)
    path = safePath(path)
    if ghost and (not path or not file.Exists("materials/" .. path .. ".vmt", "GAME")) then
        path = RFGeoMod.DefaultSurfaceMaterial
    end
    if not path then return end
    local key = path .. (ghost and ":ghost" or ":icon")
    if previewMaterials[key] ~= nil then return previewMaterials[key] end
    local source = Material(path)
    local texture = not source:IsError() and source:GetTexture("$basetexture")
    local base = texture and not texture:IsError() and texture:GetName()
    if not base and not ghost then previewMaterials[key] = false return false end
    local params = {["$basetexture"] = base or "dev/dev_measurewall01a", ["$vertexcolor"] = "1", ["$translucent"] = "1"}
    if ghost then params["$vertexalpha"] = "1" end
    previewMaterials[key] = CreateMaterial("rf_geomod_wall_" .. (ghost and "ghost_" or "icon_") .. util.CRC(path), "UnlitGeneric", params)
    return previewMaterials[key]
end

local ghost = {}
local function ghostMesh(thickness, width, height, repeatSize)
    local key = thickness .. ":" .. width .. ":" .. height .. ":" .. repeatSize
    if ghost.key == key and ghost.mesh then return ghost.mesh end
    if ghost.mesh then ghost.mesh:Destroy() ghost.mesh = nil end
    local box = RFGeoMod and RFGeoMod.Box and RFGeoMod.Box(Vector(-thickness / 2, -width / 2, 0), Vector(thickness / 2, width / 2, height))
    if not box then return end
    local vertices = {}
    for _, face in ipairs(box.faces) do
        local n = face.normal
        local u = n:Cross(Vector(0, 0, 1))
        if u:LengthSqr() < 0.1 then u = Vector(1, 0, 0) else u:Normalize() end
        local v = n:Cross(u)
        local function add(p)
            vertices[#vertices + 1] = {pos = p, normal = n, u = p:Dot(u) / repeatSize, v = p:Dot(v) / repeatSize,
                color = Color(255, 255, 255, 140)}
        end
        for i = 2, #face.points - 1 do add(face.points[1]) add(face.points[i + 1]) add(face.points[i]) end
    end
    ghost.mesh = Mesh() ghost.mesh:BuildFromTriangles(vertices)
    ghost.key = key
    return ghost.mesh
end

hook.Add("PostDrawTranslucentRenderables", "rf_geomod_wall_ghost", function(_, sky)
    if sky then return end
    local ply = LocalPlayer()
    local weapon = IsValid(ply) and ply:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or not weapon.GetMode or weapon:GetMode() ~= "rf_geomod_wall" then return end
    local trace = ply:GetEyeTrace()
    if not trace.Hit or trace.HitSky then return end
    local thickness, width, height = sizes(function(name) return GetConVarString("rf_geomod_wall_" .. name) end)
    local repeatSize = math.Clamp(GetConVarNumber("rf_geomod_wall_surface_repeat"), 8, 1024)
    local pos, ang = placement(trace, ply, thickness, height)
    local mesh = ghostMesh(thickness, width, height, repeatSize)
    if not mesh then return end
    local matrix = Matrix() matrix:SetTranslation(pos) matrix:SetAngles(ang)
    cam.PushModelMatrix(matrix)
    render.SetMaterial(previewMaterial(GetConVarString("rf_geomod_wall_surface_material"), true))
    mesh:Draw()
    cam.PopModelMatrix()
    render.DrawWireframeBox(pos, ang, Vector(-thickness / 2, -width / 2, 0), Vector(thickness / 2, width / 2, height),
        Color(140, 210, 255), true)
end)

local function materialPicker(panel, label, convar)
    panel:TextEntry("Material path", convar)
    local button = panel:Button("Browse " .. string.lower(label))
    button.DoClick = function()
        openMaterialBrowser(label, GetConVarString(convar), safePath, previewMaterial, function(path)
            RunConsoleCommand(convar, path)
        end)
    end
end

function TOOL.BuildCPanel(panel)
    panel:Help("#tool.rf_geomod_wall.desc")
    local defaults = {}
    for name, value in pairs(DEFAULTS) do defaults["rf_geomod_wall_" .. name] = value end
    panel:ToolPresets("rf_geomod_wall", defaults)
    panel:NumSlider("Thickness", "rf_geomod_wall_thickness", 2, 256, 0)
    panel:NumSlider("Width", "rf_geomod_wall_width", 8, 1024, 0)
    panel:NumSlider("Height", "rf_geomod_wall_height", 8, 1024, 0)
    panel:NumSlider("Hardness", "rf_geomod_wall_hardness", 0, 100, 0)
    panel:ControlHelp("0 = soft rock. 50 = standard craters. 100 = hard concrete.")
    panel:CheckBox("Spawn frozen", "rf_geomod_wall_frozen")
    local effects = panel:ComboBox("Destruction effects", "rf_geomod_wall_effects_profile")
    for _, id in ipairs(table.GetKeys(RFGeoMod.GetEffectProfiles())) do
        effects:AddChoice(RFGeoMod.GetEffectProfile(id).label, id)
    end
    local function category(title)
        local form = vgui.Create("DForm")
        form:SetLabel(title)
        form:SetExpanded(false)
        panel:AddItem(form)
        return form
    end
    local outside = category("Outside material")
    materialPicker(outside, "Outside material", "rf_geomod_wall_surface_material")
    outside:NumSlider("Outside texture size", "rf_geomod_wall_surface_repeat", 8, 1024, 0)
    local inside = category("Broken inside material")
    materialPicker(inside, "Broken inside material", "rf_geomod_wall_cut_material")
    inside:NumSlider("Inside texture size", "rf_geomod_wall_cut_repeat", 8, 1024, 0)
end
