-- Trajectory preview: while the local player lines up a shot, draw where the ball will fly and land
-- for the club in their hands. Before the swing it shows a full-power shot; during the swing it
-- follows the power meter. Only this player sees it.
local Golf = require("golf")
local Trajectory = require("trajectory")
local Render = require("render")

local Preview = {}

local FRAMES_PER_UPDATE = 2   -- ~30-60 updates a second is plenty for a guide line
local FLIGHT_STEP = 1 / 15    -- seconds between traced points along the flight
local MAX_FLIGHT_TIME = 10
local DOTS = 48
local STYLE = {
    dots = DOTS,
    dotColor = { R = 1, G = 1, B = 1, A = 1 },
    ringColor = { R = 1, G = 0.72, B = 0.08, A = 1 },
}

local enabled = function() return true end
local renderer = nil
local lastState = nil

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function valid(object) return object ~= nil and object:IsValid() end

local function dotSize(distance)
    return math.max(4, math.min(45, distance * 0.005))
end

local function ringSize(distance)
    return math.max(60, math.min(400, distance * 0.02))
end

local function pathLength(points)
    local total = 0
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        total = total + math.sqrt((b.X - a.X) ^ 2 + (b.Y - a.Y) ^ 2 + (b.Z - a.Z) ^ 2)
    end
    return total
end

local function hide(state)
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

local function update()
    if not enabled() then return hide("off") end
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.Pawn) then return hide("no player") end
    local pawn = controller.Pawn
    local club = Golf.heldClub(pawn)
    if club == nil then return hide("no club in hand") end
    local ball = Golf.addressedBall(club, pawn)
    if ball == nil then return hide("no ball to hit") end

    local shot = Golf.shot(club, ball, pawn)
    local target = Trajectory.target(shot.start, shot.yaw, shot.distance)
    local velocity = Trajectory.launchVelocity(shot.start, target, shot.arc, shot.gravityZ)
    if velocity == nil then return hide("no arc") end
    local flight = Trajectory.fly(shot.start, velocity, {
        gravityZ = shot.gravityZ, damping = shot.damping, step = FLIGHT_STEP, maxTime = MAX_FLIGHT_TIME,
        hitTest = Golf.hitTest(pawn, { ball, pawn, club }),
    })

    local camera = Golf.camera(controller) or shot.start
    local draw = rendererFor(pawn:GetWorld())
    local spacing = math.max(20, pathLength(flight.points) / (DOTS - 1))
    draw:showDots(Render.resample(flight.points, spacing), camera, dotSize)
    if flight.landing then
        local l = flight.landing.location
        local distance = math.sqrt((l.X - camera.X) ^ 2 + (l.Y - camera.Y) ^ 2 + (l.Z - camera.Z) ^ 2)
        draw:showRing(l, flight.landing.normal, ringSize(distance))
    else
        draw:hideRing()
    end
    local state = shot.swinging and "following swing power" or "showing full-power shot"
    if state ~= lastState then
        lastState = state
        log(string.format("preview: %s (%s, %.0f m)", state, club:GetClass():GetFName():ToString(), shot.distance / 100))
    end
end

-- isEnabled: function returning whether the preview setting is on.
function Preview.start(isEnabled)
    enabled = isEnabled
    LoopInGameThreadAfterFrames(FRAMES_PER_UPDATE, function()
        local ok, err = pcall(update)
        if not ok then hide("error: " .. tostring(err)) end
    end)
end

return Preview
