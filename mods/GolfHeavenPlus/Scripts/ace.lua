-- Hole-in-one mode, the host's secret (F6 toggles it): the local player's balls steer themselves
-- into the current hole's cup. In the air a ball keeps its own arc while its sideways speed is
-- re-aimed every frame to come down on the cup; on the ground it rolls straight at the cup, slowing
-- so it drops; close to the cup it heads for the inside of it. Only the machine that simulates a
-- ball can steer it, which in a hosted round is the host, so guests can't turn it on.
local Golf = require("golf")
local Loop = require("loop")
local Cup = require("cup")

local Ace = {}

local ROLL_DECEL = 323   -- cm/s²: how hard a green slows a rolling ball (measured from putts)
local ARRIVE_SPEED = 90  -- cm/s left when a rolling ball reaches the cup, slow enough to drop
local AIR_GAIN = 0.35    -- share of the gap to the right sideways velocity closed each frame in the air
local GROUND_TRACE = 10  -- cm below the ball's centre that counts as touching the ground
local DUNK_RADIUS = 90   -- cm: this close to the cup (and no higher above it) the ball heads into it
local DUNK_SPEED = 180   -- cm/s
local DUNK_DEPTH = 10    -- cm below the cup's rim the ball aims for
local TELEPORT = 500     -- cm moved in one frame: the game put the ball back (water, out of bounds)
local MAX_SECONDS = 30
local GRAVITY = 980

local on = false
local homing = {} -- ball address -> { ball, cup, hitTest, started, last }
local NONE, statics = nil, nil

local function valid(object) return object ~= nil and object:IsValid() end

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function now(context)
    local ok, t = pcall(function() return statics:GetTimeSeconds(context) end)
    return ok and t or os.time()
end

function Ace.isOn() return on end

-- Velocity that takes a ball at `p` moving at `v` into the cup `c` this frame (see the header).
-- grounded: whether the ball is touching the ground. Pure maths, for the tests.
function Ace.steer(p, v, c, grounded)
    local dx, dy = c.X - p.X, c.Y - p.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < DUNK_RADIUS and p.Z < c.Z + DUNK_RADIUS then
        local tz = c.Z - DUNK_DEPTH - p.Z
        local len = math.max(math.sqrt(dx * dx + dy * dy + tz * tz), 1)
        return { X = dx / len * DUNK_SPEED, Y = dy / len * DUNK_SPEED, Z = tz / len * DUNK_SPEED }
    end
    local reach = v.Z * v.Z + 2 * GRAVITY * (p.Z - c.Z) -- negative: the arc never gets back up to the cup
    if grounded or reach < 0 then
        local speed = math.sqrt(2 * ROLL_DECEL * dist + ARRIVE_SPEED * ARRIVE_SPEED)
        local d = math.max(dist, 1)
        return { X = dx / d * speed, Y = dy / d * speed, Z = v.Z }
    end
    local fall = math.max((v.Z + math.sqrt(reach)) / GRAVITY, 0.05) -- seconds until it's down at the cup
    return { X = v.X + (dx / fall - v.X) * AIR_GAIN, Y = v.Y + (dy / fall - v.Y) * AIR_GAIN, Z = v.Z }
end

-- One frame for one ball; false once it's done (in the cup, reset by the game, or given up on).
local function step(entry)
    local ball = entry.ball
    if ball.BallIsInCup or now(ball) - entry.started > MAX_SECONDS then return false end
    local p = ball:K2_GetActorLocation()
    local last = entry.last
    entry.last = { X = p.X, Y = p.Y, Z = p.Z }
    if last ~= nil and (p.X - last.X) ^ 2 + (p.Y - last.Y) ^ 2 + (p.Z - last.Z) ^ 2 > TELEPORT ^ 2 then return false end
    if not Golf.simulatesHere(ball) then return true end
    local mesh = ball.StaticMesh
    local grounded = entry.hitTest(p, { X = p.X, Y = p.Y, Z = p.Z - GROUND_TRACE }) ~= nil
    mesh:SetPhysicsLinearVelocity(Ace.steer(p, mesh:GetPhysicsLinearVelocity(NONE), entry.cup, grounded), false, NONE)
    return true
end

function Ace.update()
    if next(homing) == nil then return end
    for key, entry in pairs(homing) do
        local keep = valid(entry.ball)
        if keep then
            local ok, result = pcall(step, entry)
            keep = ok and result
            if not ok then log("ace: " .. tostring(result)) end
        end
        if not keep then homing[key] = nil end
    end
end

-- The local player just hit a ball with hole-in-one mode on: send it to the current hole's cup.
local function onHit(ball, putt, hitter)
    if not on or not Golf.isLocal(hitter) then return end
    local p = ball:K2_GetActorLocation()
    local target = Golf.currentCup() or p
    local cup = Cup.nearest(target) or Golf.currentCup()
    if cup == nil then return end
    local key = ball:GetAddress()
    if homing[key] == nil then log(string.format("ace: homing into the cup %.0f m away", math.sqrt((cup.X - p.X) ^ 2 + (cup.Y - p.Y) ^ 2) / 100)) end
    homing[key] = { ball = ball, cup = { X = cup.X, Y = cup.Y, Z = cup.Z }, hitTest = Golf.hitTest(ball, { ball }), started = now(ball) }
end

function Ace.toggle()
    local controller = Golf.localController()
    if not on and not (valid(controller) and controller:HasAuthority()) then
        log("ace: hole-in-one mode only works for the host")
        return
    end
    on = not on
    if not on then homing = {} end
    log("ace: hole-in-one mode " .. (on and "on" or "off"))
end

-- key: the UE4SS Key that toggles hole-in-one mode.
function Ace.start(key)
    NONE = FName("None")
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    Golf.onHit(onHit)
    RegisterKeyBind(key, function() ExecuteInGameThread(Ace.toggle) end)
    Loop.every(1, "ace", Ace.update)
end

return Ace
