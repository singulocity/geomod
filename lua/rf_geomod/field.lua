-- Static group container: source planes, chunk lattice, cut history and job scheduler.
-- Surface geometry is the exact polygon boundary in surface.lua; hit queries are
-- in field_queries.lua. No sampled distance field or contouring remains (RF-094).
RFGeoMod=RFGeoMod or {}
if RFGeoMod.Field then return RFGeoMod.Field end
RFGeoMod.Field={}
local V=RFGeoMod.Field
local axes={'x','y','z'}

-- A job owns its work until completion. Checkpoints never publish a partially
-- constructed surface; native physics/GPU uploads remain atomic.
function V.NewJob(fn,clock)
    local job={clock=clock or SysTime,cpu=0,steps=0,max_step=0,paused=0}
    function job:Time() return self.clock()-self.paused end
    function job:Checkpoint()
        if self.clock()<self.deadline then return end
        local at=self.clock()
        coroutine.yield()
        self.paused=self.paused+self.clock()-at
    end
    job.thread=coroutine.create(function() job.result=fn(job,function() job:Checkpoint() end) end)
    return job
end
function V.Step(job,budget)
    local at=job.clock() job.deadline=at+budget
    local ok,err=coroutine.resume(job.thread)
    local elapsed=job.clock()-at
    job.cpu=job.cpu+elapsed job.steps=job.steps+1 job.max_step=math.max(job.max_step,elapsed)
    assert(ok,err)
    job.done=coroutine.status(job.thread)=='dead'
    return job.done
end

function V.SameTriangles(a,b)
    if not a or not b or #a~=#b then return false end
    for i,t in ipairs(a) do
        local u=b[i]
        if t.mat~=u.mat or t.face~=u.face or t.normal:DistToSqr(u.normal)>1e-16 then return false end
        for j=1,3 do if t[j]:DistToSqr(u[j])>1e-16 then return false end end
    end
    return true
end

local methods={}
methods.__index=methods

-- `spacing` and `chunkCells` define the world-aligned chunk lattice that buckets
-- polygons into physics/render entities. It no longer samples anything.
function V.New(pieces,low,high,spacing,chunkCells)
    local step=spacing
    if type(spacing)=='number' or spacing==nil then step=Vector(spacing or 8,spacing or 8,spacing or 8) end
    local counts={}
    for i,a in ipairs(axes) do counts[i]=type(chunkCells)=='number' and chunkCells or
        (chunkCells and chunkCells[a] or math.max(1,math.floor(128/step[a]))) end
    local self=setmetatable({pieces=pieces,spacing=step,chunkCells=counts,
        chunks={},sourcePlanes={},queryCuts={},revision=0},methods)
    for _,piece in ipairs(pieces) do
        local planes={}
        for _,face in ipairs(piece.faces) do
            planes[#planes+1]={face.normal.x,face.normal.y,face.normal.z,face.d,face}
        end
        -- Vertex bounds let exact ray queries reject brushes a segment misses.
        if piece.low and piece.high then
            planes.lx,planes.ly,planes.lz=piece.low.x,piece.low.y,piece.low.z
            planes.hx,planes.hy,planes.hz=piece.high.x,piece.high.y,piece.high.z
        end
        self.sourcePlanes[#self.sourcePlanes+1]=planes
    end
    self.origin=Vector() self.size={}
    for i,a in ipairs(axes) do
        -- Half-cell offset keeps lattice planes off authored brush faces.
        self.origin[a]=math.floor(low[a]/step[a])*step[a]-step[a]*1.5
        self.size[i]=math.ceil((high[a]-self.origin[a])/step[a])+2
    end
    return self
end

function methods:ChunkKey(x,y,z) return x..':'..y..':'..z end
function methods:AllChunks()
    if self.sourceChunkList then
        local result={} for i,chunk in ipairs(self.sourceChunkList) do result[i]=chunk end return result
    end
    local list={}
    for x=0,math.floor(self.size[1]/self.chunkCells[1]) do
        for y=0,math.floor(self.size[2]/self.chunkCells[2]) do
            for z=0,math.floor(self.size[3]/self.chunkCells[3]) do
                list[#list+1]={x=x,y=y,z=z,key=self:ChunkKey(x,y,z)}
            end
        end
    end
    return list
end

function V.UV(triangle,p,repeatSize)
    if triangle.face and triangle.face.uv then
        local uv=triangle.face.uv
        return (p:Dot(uv.u)+uv.uo)/uv.width,(p:Dot(uv.v)+uv.vo)/uv.height
    end
    local n=triangle.normal
    local u=math.abs(n.z)>.9 and Vector(1,0,0) or n:Cross(Vector(0,0,1)):GetNormalized()
    return p:Dot(u)/(repeatSize or 128),p:Dot(n:Cross(u))/(repeatSize or 128)
end

return V
