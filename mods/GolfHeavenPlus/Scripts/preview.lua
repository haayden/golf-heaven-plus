-- Trajectory preview: while the local player lines up a shot, draw where the ball will fly and land
-- for the club in their hands. Before the swing it shows a full-power shot; during the swing it
-- follows the power meter. Only this player sees it.
local Golf = require("golf")
local Trajectory = require("trajectory")
local Render = require("render")
local Loop = require("loop")

local Preview = {}

local FRAMES_PER_UPDATE = 2   -- ~30-60 updates a second is plenty for a guide line
local FLIGHT_STEP = 1 / 15    -- seconds between traced points along the flight
local MAX_FLIGHT_TIME = 10
local SEGMENTS = 64           -- tubes per line
local STEP_FRACTION = 0.07    -- each tube spans about 4 degrees of view, wherever it is
local MIN_STEP = 3            -- cm: the shortest tube, right at the golfer's feet
local GROUND_TRACE_DEPTH = 10000 -- how far below the arc to look for the ground
local LOW_SHOT = 100             -- shots that never rise this high (putts) don't need a ground line
local GRASS_HEIGHT = 3           -- cm the ground line floats above the traced surface
local UP = { X = 0, Y = 0, Z = 1 }
local STYLE = {
    lines = {
        arc = { segments = SEGMENTS, color = { R = 1, G = 1, B = 1, A = 1 } },
        ground = { segments = SEGMENTS, color = { R = 1, G = 0.85, B = 0.3, A = 1 } },
    },
    ringColor = { R = 1, G = 0.72, B = 0.08, A = 1 },
}

local enabled = function() return true end
local renderer = nil
local lastState = nil
local lastKey = nil   -- what the lines were last drawn for; unchanged inputs skip the redraw
local addressed = nil -- the ball being lined up, remembered across updates

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function valid(object) return object ~= nil and object:IsValid() end

-- Line thickness in cm at a distance from the camera: about a quarter of a degree on screen.
local function arcWidth(distance) return math.max(0.8, math.min(80, distance * 0.0045)) end
local function groundWidth(distance) return math.max(0.8, math.min(70, distance * 0.004)) end

-- Landing marker diameter: about a degree of view, so it never hides a nearby cup.
local function ringSize(distance)
    return math.max(10, math.min(400, distance * 0.02))
end

-- The marker lies on the ground; a landing against a wall or the cup's side would stand it on edge.
local function flatNormal(normal)
    if normal.Z < 0.7 then return UP end
    return normal
end

-- The arc's shadow on the terrain: the line a golfer sees leaving the ball while looking down at it.
local function groundTrack(points, hitTest)
    local track = {}
    for _, p in ipairs(points) do
        local hit = hitTest(p, { X = p.X, Y = p.Y, Z = p.Z - GROUND_TRACE_DEPTH })
        if hit then
            local l = hit.location
            track[#track + 1] = { X = l.X, Y = l.Y, Z = l.Z, normal = hit.normal }
        end
    end
    return track
end

-- Floats a ground-line tube just over the grass: fairway blades and terrain bumps between traced
-- points (and the coarser terrain far away) would otherwise bury it in dashes.
local function onGround(p, width)
    local n, up = p.normal or UP, width * 1.5 + GRASS_HEIGHT
    return { X = p.X + n.X * up, Y = p.Y + n.Y * up, Z = p.Z + n.Z * up }
end

local function hide(state)
    lastKey = nil
    if renderer ~= nil and renderer:isValid() then renderer:hide() end
    if state ~= lastState then
        lastState = state
        log("preview: " .. state)
    end
end

local function rendererFor(world)
    if renderer ~= nil and renderer:isValid() and renderer.world:GetAddress() == world:GetAddress() then
        return renderer
    end
    renderer = Render.new(world, STYLE)
    return renderer
end

local function inputsKey(shot, camera)
    local s = shot.start
    return string.format("%.1f,%.1f,%.1f|%.2f|%.0f|%.3f|%.0f,%.0f,%.0f", s.X, s.Y, s.Z, shot.yaw, shot.distance, shot.arc,
        camera.X, camera.Y, camera.Z)
end

local function update()
    if not enabled() then return hide("off") end
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.Pawn) then return hide("no player") end
    local pawn = controller.Pawn
    local club = Golf.heldClub(pawn)
    if club == nil then return hide("no club in hand") end
    addressed = Golf.addressedBall(pawn, addressed)
    local ball = addressed
    if ball == nil then return hide("no ball to hit") end

    local shot = Golf.shot(club, ball, pawn)
    local camera = Golf.camera(controller) or shot.start
    local key = inputsKey(shot, camera)
    if key == lastKey then return end

    local target = Trajectory.target(shot.start, shot.yaw, shot.distance)
    local velocity = Trajectory.launchVelocity(shot.start, target, shot.arc, shot.gravityZ)
    if velocity == nil then return hide("no arc") end
    local hitTest = Golf.hitTest(pawn, { ball, pawn, club })
    local flight = Trajectory.fly(shot.start, velocity, {
        gravityZ = shot.gravityZ, damping = shot.damping, step = FLIGHT_STEP, maxTime = MAX_FLIGHT_TIME,
        hitTest = hitTest,
    })

    local draw = rendererFor(pawn:GetWorld())
    local arc = Render.resampleAdaptive(flight.points, camera, STEP_FRACTION, MIN_STEP, SEGMENTS + 1)
    draw:showLine("arc", arc, camera, arcWidth)
    local peak = shot.start.Z
    for _, p in ipairs(flight.points) do peak = math.max(peak, p.Z) end
    -- Putts only hop before rolling, so neither the ground line nor a landing spot means anything.
    local lofted = peak - shot.start.Z > LOW_SHOT
    if lofted then
        draw:showLine("ground", groundTrack(arc, hitTest), camera, groundWidth, onGround)
    else
        draw:hideLine("ground")
    end
    if lofted and flight.landing then
        local l = flight.landing.location
        local distance = math.sqrt((l.X - camera.X) ^ 2 + (l.Y - camera.Y) ^ 2 + (l.Z - camera.Z) ^ 2)
        draw:showRing(l, flatNormal(flight.landing.normal), ringSize(distance))
    else
        draw:hideRing()
    end
    lastKey = key
    local state = shot.swinging and "following swing power" or "showing full-power shot"
    if state ~= lastState then
        lastState = state
        log(string.format("preview: %s (%s, %.0f m)", state, club:GetClass():GetFName():ToString(), shot.distance / 100))
    end
end

-- isEnabled: function returning whether the preview setting is on.
function Preview.start(isEnabled)
    enabled = isEnabled
    ExecuteInGameThread(function()
        local ok, removed = pcall(Render.removeStale)
        if ok and removed > 0 then log(string.format("removed %d markers left by a previous load", removed)) end
    end)
    Loop.every(FRAMES_PER_UPDATE, "trajectory", function()
        local ok, err = pcall(update)
        if not ok then hide("error: " .. tostring(err)) end
    end)
end

return Preview
