-- Local-only marker meshes: pools of thin tubes that draw polylines, plus a flat ring for a spot
-- on the ground. Everything is spawned on this machine only (no replication, no collision, no
-- shadows), so other players never see it and it can't touch the ball.
local Render = {}
Render.__index = Render

local ACTOR_CLASS = "/Script/Engine.StaticMeshActor"
local SPHERE = "/Engine/BasicShapes/Sphere.Sphere" -- only used by older versions; still cleaned up
local CYLINDER = "/Engine/BasicShapes/Cylinder.Cylinder"
local MATERIAL = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local MOVABLE = 2           -- EComponentMobility::Movable
local NO_COLLISION = 0      -- ECollisionEnabled::NoCollision
local BASIC_SHAPE_SIZE = 100 -- engine basic shapes are 100 units across

local function valid(object) return object ~= nil and object:IsValid() end

local function spawnMarker(world, mesh, color)
    local actor = world:SpawnActor(StaticFindObject(ACTOR_CLASS), { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(actor) then return nil end
    actor:SetReplicates(false)
    local component = actor.StaticMeshComponent
    component:SetMobility(MOVABLE)
    component:SetStaticMesh(mesh)
    component:SetCollisionEnabled(NO_COLLISION)
    component:SetCastShadow(false)
    local material = component:CreateDynamicMaterialInstance(0, StaticFindObject(MATERIAL), FName("None"))
    if valid(material) then material:SetVectorParameterValue(FName("Color"), color) end
    actor:SetActorHiddenInGame(true)
    return actor
end

local function spawnPool(world, mesh, count, color)
    local pool = {}
    for i = 1, count do
        local actor = spawnMarker(world, mesh, color)
        if actor == nil then break end
        pool[i] = actor
    end
    return pool
end

-- Hidden state is tracked in Lua so each frame only touches markers whose visibility changed.
local function setHidden(self, actor, hidden)
    if self.hidden[actor] == hidden then return end
    self.hidden[actor] = hidden
    actor:SetActorHiddenInGame(hidden)
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Points spaced `spacing` apart along the polyline `path` (a list of {X, Y, Z}).
function Render.resample(path, spacing)
    local points = {}
    if #path == 0 then return points end
    points[1] = path[1]
    local carried = 0
    for i = 2, #path do
        local a, b = path[i - 1], path[i]
        local dx, dy, dz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        local travelled = spacing - carried
        while travelled <= length do
            local f = travelled / length
            points[#points + 1] = { X = a.X + dx * f, Y = a.Y + dy * f, Z = a.Z + dz * f }
            travelled = travelled + spacing
        end
        carried = length - (travelled - spacing)
    end
    return points
end

local function walkAdaptive(path, viewer, fraction, minStep, limit)
    local points = { path[1] }
    local from, i = path[1], 2
    local want = math.max(minStep, fraction * distance(from, viewer))
    while i <= #path do
        local to = path[i]
        local length = distance(from, to)
        if length >= want and length > 0 then
            local f = want / length
            from = { X = from.X + (to.X - from.X) * f, Y = from.Y + (to.Y - from.Y) * f, Z = from.Z + (to.Z - from.Z) * f }
            points[#points + 1] = from
            if #points > limit then return nil end
            want = math.max(minStep, fraction * distance(from, viewer))
        else
            want = want - length
            from = to
            i = i + 1
        end
    end
    local last = path[#path]
    if distance(points[#points], last) > 1e-6 then points[#points + 1] = last end
    if #points > limit then return nil end
    return points
end

-- Points along `path` whose spacing grows with distance from `viewer` (`fraction` of it, at least
-- `minStep`), so a line drawn through them is equally smooth up close and far away. Starts and
-- ends on the path's ends. Never returns more than `maxPoints`: it spaces them wider instead.
function Render.resampleAdaptive(path, viewer, fraction, minStep, maxPoints)
    if #path <= 1 then return { path[1] } end
    minStep = math.max(minStep, 1e-3)
    for _ = 1, 16 do
        local points = walkAdaptive(path, viewer, fraction, minStep, maxPoints)
        if points then return points end
        fraction, minStep = math.max(fraction * 1.5, 0.01), minStep * 1.5
    end
    return { path[1], path[#path] }
end

-- Transform that stretches the engine cylinder (100 units tall along Z) from `a` to `b` as a tube
-- `width` thick. Each end overlaps by half a width so bends in a polyline show no gaps.
function Render.segmentTransform(a, b, width)
    local dx, dy, dz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1e-6 then return nil end
    dx, dy, dz = dx / length, dy / length, dz / length
    -- Shortest rotation from +Z to the segment direction.
    local qx, qy, qw = -dy, dx, 1 + dz
    local norm = math.sqrt(qx * qx + qy * qy + qw * qw)
    local rotation
    if norm < 1e-9 then
        rotation = { X = 1, Y = 0, Z = 0, W = 0 } -- straight down: half a turn about X
    else
        rotation = { X = qx / norm, Y = qy / norm, Z = 0, W = qw / norm }
    end
    local s = width / BASIC_SHAPE_SIZE
    return {
        Rotation = rotation,
        Translation = { X = (a.X + b.X) / 2, Y = (a.Y + b.Y) / 2, Z = (a.Z + b.Z) / 2 },
        Scale3D = { X = s, Y = s, Z = (length + width) / BASIC_SHAPE_SIZE },
    }
end

-- options: { lines = { name = { segments = N, color = {R,G,B,A} }, ... }, ringColor = {R,G,B,A} }
function Render.new(world, options)
    local self = setmetatable({ world = world, lines = {}, hidden = {} }, Render)
    local cylinder = StaticFindObject(CYLINDER)
    for name, line in pairs(options.lines) do
        self.lines[name] = spawnPool(world, cylinder, line.segments, line.color)
        for _, actor in ipairs(self.lines[name]) do self.hidden[actor] = true end
    end
    self.ring = spawnMarker(world, cylinder, options.ringColor)
    if self.ring then self.hidden[self.ring] = true end
    return self
end

function Render:isValid()
    if not valid(self.world) then return false end
    for _, pool in pairs(self.lines) do
        if pool[1] == nil or not valid(pool[1]) then return false end
    end
    return true
end

-- Draws the polyline `points` with the named line's tubes; `widthAt(distance)` gives the tube's
-- thickness at a distance from `viewer`, so the line keeps a steady on-screen weight.
-- `lift(point, width)` optionally moves each point (e.g. up off the ground by the tube's radius).
function Render:showLine(name, points, viewer, widthAt, lift)
    local pool = self.lines[name]
    for i, actor in ipairs(pool) do
        local a, b = points[i], points[i + 1]
        local transform = nil
        if a ~= nil and b ~= nil then
            local width = widthAt(distance({ X = (a.X + b.X) / 2, Y = (a.Y + b.Y) / 2, Z = (a.Z + b.Z) / 2 }, viewer))
            if lift then a, b = lift(a, width), lift(b, width) end
            transform = Render.segmentTransform(a, b, width)
        end
        if transform == nil then
            setHidden(self, actor, true)
        else
            actor:K2_SetActorTransform(transform, false, {}, true)
            setHidden(self, actor, false)
        end
    end
end

function Render:hideLine(name)
    for _, actor in ipairs(self.lines[name]) do
        if valid(actor) then setHidden(self, actor, true) end
    end
end

-- A thin disc of `diameter` lying on the surface at `location` facing `normal`.
function Render:showRing(location, normal, diameter)
    if not valid(self.ring) then return end
    local math3d = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local rotation = math3d:MakeRotFromZ(normal)
    local s = diameter / BASIC_SHAPE_SIZE
    local lifted = { X = location.X + normal.X * 2, Y = location.Y + normal.Y * 2, Z = location.Z + normal.Z * 2 }
    self.ring:K2_SetActorLocationAndRotation(lifted, rotation, false, {}, true)
    self.ring:SetActorScale3D({ X = s, Y = s, Z = 0.02 })
    setHidden(self, self.ring, false)
end

function Render:hideRing()
    if valid(self.ring) then setHidden(self, self.ring, true) end
end

function Render:hide()
    for name in pairs(self.lines) do self:hideLine(name) end
    self:hideRing()
end

-- UE4SS has no unload callback, so a hot reload leaves the previous copy's markers in the world.
-- Ours are the only StaticMeshActors showing an engine basic shape through a dynamic instance of
-- BasicShapeMaterial; destroy those. Returns how many were removed.
function Render.removeStale()
    local shapes = {}
    for _, path in ipairs({ SPHERE, CYLINDER }) do
        local mesh = StaticFindObject(path)
        if valid(mesh) then shapes[mesh:GetAddress()] = true end
    end
    local material = StaticFindObject(MATERIAL)
    if not valid(material) then return 0 end
    local removed = 0
    for _, actor in ipairs(FindAllOf("StaticMeshActor") or {}) do
        local ok, ours = pcall(function()
            local component = actor.StaticMeshComponent
            if not shapes[component.StaticMesh:GetAddress()] then return false end
            local instance = component:GetMaterial(0)
            return valid(instance) and valid(instance.Parent) and instance.Parent:GetAddress() == material:GetAddress()
                and instance:GetClass():GetFName():ToString() == "MaterialInstanceDynamic"
        end)
        if ok and ours then
            actor:K2_DestroyActor()
            removed = removed + 1
        end
    end
    return removed
end

function Render:destroy()
    for _, pool in pairs(self.lines) do
        for _, actor in ipairs(pool) do
            if valid(actor) then actor:K2_DestroyActor() end
        end
    end
    if valid(self.ring) then self.ring:K2_DestroyActor() end
    self.lines, self.ring = {}, nil
end

return Render
