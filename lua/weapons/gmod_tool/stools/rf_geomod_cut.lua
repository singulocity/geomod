TOOL.Category = "GeoMod"
TOOL.Name = "#tool.rf_geomod_cut.name"
TOOL.Information = {{name = "left"}}
TOOL.ClientConVar = {radius = "48"}

local function target(trace)
    if not trace.Hit or trace.HitSky or trace.StartSolid then return end
    return RFGeoMod.ContactWall(trace.Entity)
end

function TOOL:LeftClick(trace)
    local wall = target(trace)
    if not IsValid(wall) then return false end
    if CLIENT then return true end
    local ply = self:GetOwner()
    local now = CurTime()
    if now < (ply.GeoModNextToolCut or 0) then return false end
    if not RFGeoMod.CutContact(wall, trace.HitPos, trace.HitNormal, self:GetClientNumber("radius", 48)) then
        return false
    end
    ply.GeoModNextToolCut = now + .15
    return true
end

if SERVER then return end

language.Add("tool.rf_geomod_cut.name", "GeoMod Cut")
language.Add("tool.rf_geomod_cut.desc", "Carve a crater into a GeoMod wall")
language.Add("tool.rf_geomod_cut.left", "Cut the highlighted volume")

local previewFaces
local previewColor = Color(90, 225, 255)
hook.Add("PostDrawTranslucentRenderables", "rf_geomod_cut_ghost", function(depth, sky)
    if depth or sky then return end
    local ply = LocalPlayer()
    local weapon = IsValid(ply) and ply:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or weapon:GetMode() ~= "rf_geomod_cut" then return end
    local trace = ply:GetEyeTrace()
    local wall = target(trace)
    if not IsValid(wall) then return end

    local dynamic = wall:GetClass() == "rf_geomod_dynamic"
    local point = dynamic and wall:WorldToLocal(trace.HitPos) or trace.HitPos
    local cut = RFGeoMod.ContactCut(point, GetConVar("rf_geomod_cut_radius"):GetFloat())
    previewFaces = previewFaces or RFGeoMod.ContactCutPreview()
    for _, face in ipairs(previewFaces) do
        local points = {}
        for i, vertex in ipairs(face.points) do
            local pos = cut.center + vertex * cut.radius
            points[i] = dynamic and wall:LocalToWorld(pos) or pos
        end
        for i, pos in ipairs(points) do
            render.DrawLine(pos, points[i % #points + 1], previewColor, false)
        end
    end
end)

function TOOL.BuildCPanel(panel)
    panel:NumSlider("Cut radius", "rf_geomod_cut_radius", 6, 150, 0)
    panel:ControlHelp("The wireframe shows the cut volume, including the part inside the wall.")
end
