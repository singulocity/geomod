-- Exact zero-set queries of the replacement's continuous implicit CSG field.
-- Immutable source planes + accepted cutters; never query dual triangles or
-- rebuild/subtract convex fragments. Source and cutters are in one world frame.
local V=RFGeoMod.Field
local EPS=1e-9
local function clip(planes,start,delta,source)
    local lo,hi=0,1
    local enter,leave,enterFace,leaveFace
    for _,p in ipairs(planes) do
        local distance=p[4]-p[1]*start.x-p[2]*start.y-p[3]*start.z
        local speed=p[1]*delta.x+p[2]*delta.y+p[3]*delta.z
        if math.abs(speed)<1e-12 then
            if distance<0 then return end
        else
            local t=distance/speed
            local normal=source and p[5].normal or p[5]
            if speed<0 then if t>lo then lo,enter,enterFace=t,normal,source and p[5] or nil end
            else if t<hi then hi,leave,leaveFace=t,normal,source and p[5] or nil end end
            if hi<lo then return end
        end
    end
    if hi-lo<=EPS then return end
    return {lo=lo,hi=hi,enter=enter,leave=leave,enterFace=enterFace,leaveFace=leaveFace}
end
local function union(intervals)
    table.sort(intervals,function(a,b) return a.lo<b.lo end)
    local result={}
    for _,interval in ipairs(intervals) do
        local last=result[#result]
        if last and interval.lo<=last.hi+EPS then
            if interval.hi>last.hi then last.hi,last.leave,last.leaveFace=interval.hi,interval.leave,interval.leaveFace end
        else result[#result+1]=interval end
    end
    return result
end
-- Conservative segment/box rejection. A convex brush lies inside its vertex
-- bounds, so a segment missing the slightly expanded box cannot clip it.
local MARGIN=.05
local function misses(planes,sx,sy,sz,dx,dy,dz)
    local lx=planes.lx if not lx then return false end
    local lo,hi=0,1
    for axis=1,3 do
        local s,d,a,b
        if axis==1 then s,d,a,b=sx,dx,lx-MARGIN,planes.hx+MARGIN
        elseif axis==2 then s,d,a,b=sy,dy,planes.ly-MARGIN,planes.hy+MARGIN
        else s,d,a,b=sz,dz,planes.lz-MARGIN,planes.hz+MARGIN end
        if math.abs(d)<1e-12 then
            if s<a or s>b then return true end
        else
            local t1,t2=(a-s)/d,(b-s)/d
            if t1>t2 then t1,t2=t2,t1 end
            if t1>lo then lo=t1 end
            if t2<hi then hi=t2 end
            if lo>hi then return true end
        end
    end
    return false
end
function V.Ray(volume,start,delta,sourceOnly)
    local solid,removed={},{}
    local sx,sy,sz,dx,dy,dz=start.x,start.y,start.z,delta.x,delta.y,delta.z
    for _,planes in ipairs(volume.sourcePlanes) do
        if not misses(planes,sx,sy,sz,dx,dy,dz) then
            local interval=clip(planes,start,delta,true)
            if interval then solid[#solid+1]=interval end
        end
    end
    if #solid==0 then return end
    solid=union(solid)
    if not sourceOnly then for _,planes in ipairs(volume.queryCuts) do
        local interval=clip(planes,start,delta,false)
        if interval then removed[#removed+1]=interval end
    end end
    removed=union(removed)
    for _,source in ipairs(solid) do
        local lo,enter,face=source.lo,source.enter,source.enterFace
        for _,cut in ipairs(removed) do
            if cut.hi>lo+EPS and cut.lo<source.hi-EPS then
                if cut.lo>lo+EPS then
                    return {Hit=true,Fraction=lo,HitPos=start+delta*lo,Normal=enter or -delta:GetNormalized(),
                        StartSolid=lo==0,AllSolid=false,FractionLeftSolid=cut.lo,FieldFace=face}
                end
                lo,enter,face=math.max(lo,cut.hi),cut.leave and -cut.leave or nil,nil
            end
            if lo>=source.hi-EPS then break end
        end
        if lo<source.hi-EPS then
            return {Hit=true,Fraction=lo,HitPos=start+delta*lo,Normal=enter or -delta:GetNormalized(),
                StartSolid=lo==0,AllSolid=lo==0 and source.hi==1,FractionLeftSolid=source.hi,FieldFace=face}
        end
    end
end
return V.Ray
