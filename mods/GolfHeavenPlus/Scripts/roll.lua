-- Real putting: a putted ball rolls instead of sliding.
-- The game launches a putt and then lets friction drag the ball to a stop while it barely spins
-- (0-3% of rolling speed in recorded putts), so it moves like a shoved puck and stops dead.
-- This takes over once a putter launches a ball: the ball spins as it rolls and slows under a
-- gentle rolling resistance, and it is launched a little slower so each stroke still travels as
-- far as the game intended. Only the host simulates balls, so only the host changes anything.
local Golf = require("golf")

local Roll = {}

local GAME_SLIDE = 323    -- cm/s²: how hard the game's friction slows a putt on a green (median of 82 putts)
local RESISTANCE = 140    -- cm/s²: rolling resistance used instead; a slow real green is around 100
local BALL_RADIUS = 4.44  -- cm: the ball's centre sits this far above a flat green
local GROUND_GAP = 3      -- cm under the ball that still counts as touching the ground
local STOP_SPEED = 2      -- cm/s: below this the game's own settling takes over
local MAX_SECONDS = 30

local function length(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function scale(v, s) return { X = v.X * s, Y = v.Y * s, Z = v.Z * s } end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end

-- Launch speed factor that keeps a stroke's distance: v^2 / (2 * slide) = (s * v)^2 / (2 * resistance).
function Roll.launchScale(resistance, slide)
    return math.sqrt(resistance / slide)
end

-- Splits velocity v into the part along the surface and the part into it (n is the unit normal).
function Roll.alongSurface(v, n)
    local into = dot(v, n)
    return { X = v.X - n.X * into, Y = v.Y - n.Y * into, Z = v.Z - n.Z * into }, into
end

-- Spin in degrees per second for rolling without slipping at surface velocity v: w = (n x v) / r.
function Roll.rollingSpin(v, n, radius)
    local k = 180 / math.pi / radius
    return {
        X = (n.Y * v.Z - n.Z * v.Y) * k,
        Y = (n.Z * v.X - n.X * v.Z) * k,
        Z = (n.X * v.Y - n.Y * v.X) * k,
    }
end

-- Velocity v after rolling resistance slows it for dt seconds; never reverses it.
function Roll.slowed(v, dt, resistance)
    local speed = length(v)
    local loss = resistance * dt
    if speed <= loss then return { X = 0, Y = 0, Z = 0 } end
    return scale(v, (speed - loss) / speed)
end

-- Runtime -----------------------------------------------------------------------------------------
local enabled = function() return true end
local rolling = {}  -- ball address -> { ball = ball, started = seconds, launch = the slowed launch velocity }
local NONE = nil
local kismet, statics = nil, nil

local function valid(object) return object ~= nil and object:IsValid() end

local function now(context)
    local ok, t = pcall(function() return statics:GetTimeSeconds(context) end)
    return ok and t or os.clock()
end

-- The ground straight under the ball, if it is touching it: { normal = {X, Y, Z} } or nil.
local function groundUnder(ball)
    local centre = ball:K2_GetActorLocation()
    local to = { X = centre.X, Y = centre.Y, Z = centre.Z - BALL_RADIUS - GROUND_GAP }
    local hit = {}
    local none = { R = 0, G = 0, B = 0, A = 0 }
    if not kismet:LineTraceSingle(ball, centre, to, 0, false, { ball }, 0, hit, true, none, none, 0) then return nil end
    local n = hit.ImpactNormal
    return { normal = { X = n.X, Y = n.Y, Z = n.Z } }
end

local function step(entry, dt, t)
    local ball = entry.ball
    local mesh = ball.StaticMesh
    local velocity = mesh:GetPhysicsLinearVelocity(NONE)
    local ground = groundUnder(ball)
    if ground == nil then return true end -- hopping off the putter, or dropping into the cup
    local along, into = Roll.alongSurface(velocity, ground.normal)
    if length(along) < STOP_SPEED then return false end
    local slower = Roll.slowed(along, dt, RESISTANCE)
    local n = ground.normal
    -- The ball's collision is a many-sided hull, not a sphere: spinning it makes its faces knock it
    -- off the ground. Keep it on the surface while it rolls (falling into the cup is untouched).
    into = math.min(into, 0)
    mesh:SetPhysicsLinearVelocity({ X = slower.X + n.X * into, Y = slower.Y + n.Y * into, Z = slower.Z + n.Z * into }, false, NONE)
    mesh:SetPhysicsAngularVelocityInDegrees(Roll.rollingSpin(slower, n, BALL_RADIUS), false, NONE)
    return t - entry.started < MAX_SECONDS
end

-- Advances every ball being rolled by one frame.
function Roll.update()
    if next(rolling) == nil then return end
    local dt = nil
    for key, entry in pairs(rolling) do
        local keep = valid(entry.ball) and not entry.ball.BallIsInCup and enabled()
        if keep then
            dt = dt or statics:GetWorldDeltaSeconds(entry.ball)
            local ok, result = pcall(step, entry, dt, now(entry.ball))
            keep = ok and result
            if not ok then print("[GolfHeavenPlus] roll: " .. tostring(result) .. "\n") end
        end
        if not keep then rolling[key] = nil end
    end
end

-- Hand a ball a putter just launched to the roller. The launch is slowed right away, so a late
-- frame can't cost distance; the game applies a hit twice, so a launch already slowed is left alone.
function Roll.take(ball)
    if not enabled() or not valid(ball) or not ball:HasAuthority() then return end
    local key = ball:GetAddress()
    local mesh = ball.StaticMesh
    local launch = mesh:GetPhysicsLinearVelocity(NONE)
    local entry = rolling[key]
    if entry and entry.launch and length({ X = launch.X - entry.launch.X, Y = launch.Y - entry.launch.Y, Z = launch.Z - entry.launch.Z }) < 1 then
        return
    end
    local slowed = scale(launch, Roll.launchScale(RESISTANCE, GAME_SLIDE))
    mesh:SetPhysicsLinearVelocity(slowed, false, NONE)
    rolling[key] = { ball = ball, started = now(ball), launch = slowed }
end

-- Looks up what the roller needs from the engine; Roll.start does this itself.
function Roll.init(isEnabled)
    enabled = isEnabled or enabled
    NONE = FName("None")
    kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
end

-- isEnabled: function returning whether the real putting setting is on.
function Roll.start(isEnabled)
    Roll.init(isEnabled)
    Golf.onHit(function(ball, putt) if putt then Roll.take(ball) end end)
    LoopInGameThreadAfterFrames(1, function()
        local ok, err = pcall(Roll.update)
        if not ok then print("[GolfHeavenPlus] roll: " .. tostring(err) .. "\n") end
    end)
end

return Roll
