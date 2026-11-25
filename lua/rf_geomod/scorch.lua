-- Planar texture projection only; never changes the wall or collision topology.
RFGeoMod=RFGeoMod or {}
function RFGeoMod.ScorchProjection(cut,normal,plane,sourceFace)
    if cut.ram then return end
    local origin=cut.scorch_origin or cut.center
    if cut.scorch_origin then
        -- Check the original face side even if contouring tilted a rim triangle.
        local facing=sourceFace and origin:Dot(sourceFace.normal)-sourceFace.d or origin:Dot(normal)-plane
        if facing<-.125 then return end
    elseif not cut.normal or normal:Dot(cut.normal)<=.25 then return end
    if math.abs(origin:Dot(normal)-plane)>=cut.radius*1.2 then return end
    local u=normal:Cross(Vector(0,0,1))
    if u:LengthSqr()<.1 then u=Vector(1,0,0) else u:Normalize() end
    local v=normal:Cross(u)
    -- Keep the stock crater size; give its surviving perimeter a soft halo.
    -- The span follows each saved cut, so all weapons and late snapshots agree.
    local span=cut.radius*4
    local angle=math.rad((cut.seed or 0)%360)
    local c,s=math.cos(angle)/span,math.sin(angle)/span
    local x,y=origin:Dot(u),origin:Dot(v)
    return {u=u,v=v,a=c,b=-s,c=s,d=c,tx=.5-c*x+s*y,ty=.5-s*x-c*y}
end

function RFGeoMod.ScorchUV(projection,point)
    local x,y=point:Dot(projection.u),point:Dot(projection.v)
    return projection.a*x+projection.b*y+projection.tx,
        projection.c*x+projection.d*y+projection.ty
end

local materials={}
local stockMaterial
function RFGeoMod.GetScorchMaterial(profile)
    local path=RFGeoMod.GetEffectProfile(profile).scorch
    if isstring(path) then
        if materials[path]==nil then materials[path]=RFGeoMod.EffectMaterial(path) or false end
        if materials[path] then return materials[path] end
    end
    -- The mounted decal shader expects a world lightmap. Use its texture with
    -- a shader that can project directly onto GeoMod's meshes.
    stockMaterial=stockMaterial or CreateMaterial('rf_geomod_stock_scorch','UnlitGeneric',{
        ['$basetexture']='decals/scorch1',
        ['$translucent']='1',
        ['$decal']='1',
        ['$basetexturetransform']='center 0 0 scale 1 1 rotate 0 translate 0 0',
    })
    return stockMaterial
end

function RFGeoMod.ScorchPasses(cuts,normal,plane,sourceFace)
    local passes={}
    local basis
    for _,cut in ipairs(cuts or {}) do
        local p=RFGeoMod.ScorchProjection(cut,normal,plane,sourceFace)
        if p then
            basis=p
            local matrix=Matrix()
            matrix:SetField(1,1,p.a) matrix:SetField(1,2,p.b)
            matrix:SetField(2,1,p.c) matrix:SetField(2,2,p.d)
            matrix:SetField(1,4,p.tx) matrix:SetField(2,4,p.ty)
            passes[#passes+1]=matrix
        end
    end
    return passes,basis
end

-- Accepted settings: 256-square texture, original world span, two alpha passes.
function RFGeoMod.DrawScorches(wall,groups)
    if #groups==0 then return end
    local mat=RFGeoMod.GetScorchMaterial(wall:GetNWString('rf_geomod_effect_profile','stock'))
    mat:SetFloat('$alpha',1)
    for _,group in ipairs(groups) do
        for layer=1,2 do
            for _,matrix in ipairs(group.passes) do
                mat:SetMatrix('$basetexturetransform',matrix)
                render.SetMaterial(mat)
                group.mesh:Draw()
            end
        end
    end
end
