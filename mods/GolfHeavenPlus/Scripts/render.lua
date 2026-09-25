-- Local-only marker meshes: a pool of dots laid along a path, plus a flat ring for a spot on the
-- ground. Everything is spawned on this machine only (no replication, no collision, no shadows),
-- so other players never see it and it can't touch the ball.
local Render = {}
Render.__index = Render

local ACTOR_CLASS = "/Script/Engine.StaticMeshActor"
local SPHERE = "/Engine/BasicShapes/Sphere.Sphere"
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

local IDENTITY = { X = 0, Y = 0, Z = 0, W = 1 }

-- Hidden state is tracked in Lua so each frame only touches markers whose visibility changed.
local function setHidden(self, actor, hidden)
    if self.hidden[actor] == hidden then return end
    self.hidden[actor] = hidden
    actor:SetActorHiddenInGame(hidden)
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

-- options: { dots = 60, dotColor = {R,G,B,A}, groundDots = 60, groundColor = {R,G,B,A}, ringColor = {R,G,B,A} }
function Render.new(world, options)
    local self = setmetatable({ world = world, dots = {}, ground = {}, options = options, hidden = {} }, Render)
    local sphere = StaticFindObject(SPHERE)
    for i = 1, options.dots do
        local dot = spawnMarker(world, sphere, options.dotColor)
        if dot == nil then break end
        self.dots[i] = dot
    end
    local disc = StaticFindObject(CYLINDER)
    for i = 1, options.groundDots or 0 do
        local dot = spawnMarker(world, disc, options.groundColor)
        if dot == nil then break end
        self.ground[i] = dot
    end
    self.ring = spawnMarker(world, disc, options.ringColor)
    for _, dot in ipairs(self.dots) do self.hidden[dot] = true end
    for _, dot in ipairs(self.ground) do self.hidden[dot] = true end
    if self.ring then self.hidden[self.ring] = true end
    return self
end

function Render:isValid()
    return valid(self.world) and self.dots[1] ~= nil and valid(self.dots[1])
end

-- Lays dots along `points`; each dot's size grows with distance from `viewer` so the arc stays
-- readable far away. `sizeAt(distance)` returns a diameter in world units.
function Render:showDots(points, viewer, sizeAt)
    for i, dot in ipairs(self.dots) do
        local point = points[i]
        if point == nil then
            setHidden(self, dot, true)
        else
            local dx, dy, dz = point.X - viewer.X, point.Y - viewer.Y, point.Z - viewer.Z
            local s = sizeAt(math.sqrt(dx * dx + dy * dy + dz * dz)) / BASIC_SHAPE_SIZE
            dot:K2_SetActorTransform({ Rotation = IDENTITY, Translation = point, Scale3D = { X = s, Y = s, Z = s } }, false, {}, true)
            setHidden(self, dot, false)
        end
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

-- Flat discs lying on the ground at `spots` ({ location, normal } each), sized like showDots.
function Render:showGround(spots, viewer, sizeAt)
    local math3d = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    for i, disc in ipairs(self.ground) do
        local spot = spots[i]
        if spot == nil then
            setHidden(self, disc, true)
        else
            local l, n = spot.location, spot.normal
            local dx, dy, dz = l.X - viewer.X, l.Y - viewer.Y, l.Z - viewer.Z
            local s = sizeAt(math.sqrt(dx * dx + dy * dy + dz * dz)) / BASIC_SHAPE_SIZE
            local lifted = { X = l.X + n.X, Y = l.Y + n.Y, Z = l.Z + n.Z }
            disc:K2_SetActorLocationAndRotation(lifted, math3d:MakeRotFromZ(n), false, {}, true)
            disc:SetActorScale3D({ X = s, Y = s, Z = 0.01 })
            setHidden(self, disc, false)
        end
    end
end

function Render:hide()
    for _, dot in ipairs(self.dots) do
        if valid(dot) then setHidden(self, dot, true) end
    end
    for _, disc in ipairs(self.ground) do
        if valid(disc) then setHidden(self, disc, true) end
    end
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
    for _, list in ipairs({ self.dots, self.ground }) do
        for _, actor in ipairs(list) do
            if valid(actor) then actor:K2_DestroyActor() end
        end
    end
    if valid(self.ring) then self.ring:K2_DestroyActor() end
    self.dots, self.ground, self.ring = {}, {}, nil
end

return Render
