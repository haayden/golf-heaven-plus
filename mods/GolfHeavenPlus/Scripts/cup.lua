-- Cup capture: a ball rolling across the hole drops in unless it is going too fast, like a real,
-- heavy golf ball. The game's greens slow balls about six times harder than a real green, so a putt
-- has to reach the hole much faster than a real one and skips over it: in recorded putts every ball
-- slower than ~210 cm/s dropped and faster ones rolled out, even ones that would have stopped a metre
-- past the hole. A real putt on line that would finish ~2 m past still drops; this restores that.
-- Only the host simulates balls, so only the host changes anything.
local Golf = require("golf")
local Loop = require("loop")

local Cup = {}

local HOLE_RADIUS = 11     -- cm: the cup's damping zone; 2.5 ball radii, the same ratio as a real cup
local CAPTURE_SPEED = 600  -- cm/s: a ball crossing dead centre slower than this drops. Game putts
                           -- travel ~2.5x real speeds, so real-golf limits (~380 here) let balls
                           -- skip that would drop in real life; only a hard hit gets over now
local BALL_RADIUS = 4.44
local RIM_BAND = 10        -- cm above resting height still counted as crossing the hole: putts
                           -- leave the face in a small hop and would otherwise float over it
local DROP_SPEED = 40      -- cm/s a captured ball keeps, pointed at the middle of the cup and down
local STILL_FRAMES = 30
local MAX_SECONDS = 30

-- Fastest a ball can cross the hole and still drop, on a path passing `offset` from the centre:
-- the time over the hole scales with the chord it crosses, and it must fall about its own radius
-- in that time, so the limit shrinks with the chord until balls on the edge just lip out.
function Cup.captureSpeed(offset, holeRadius, centreSpeed)
    if offset >= holeRadius then return 0 end
    return centreSpeed * math.sqrt(1 - (offset / holeRadius) ^ 2)
end

-- Closest the straight segment from `a` to `b` comes to `centre`, in the horizontal plane, and
-- where along it that happens ({X, Y, Z} interpolated).
function Cup.closestApproach(a, b, centre)
    local dx, dy = b.X - a.X, b.Y - a.Y
    local lengthSq = dx * dx + dy * dy
    local f = 0
    if lengthSq > 1e-9 then
        f = math.max(0, math.min(1, ((centre.X - a.X) * dx + (centre.Y - a.Y) * dy) / lengthSq))
    end
    local point = { X = a.X + dx * f, Y = a.Y + dy * f, Z = a.Z + (b.Z - a.Z) * f }
    return math.sqrt((centre.X - point.X) ^ 2 + (centre.Y - point.Y) ^ 2), point
end

-- Runtime -----------------------------------------------------------------------------------------
local enabled = function() return true end
local tracked = {} -- ball address -> { ball, started, still, last = previous location, over = cup being crossed }
local cups = {}
local NONE, statics = nil, nil

local function valid(object) return object ~= nil and object:IsValid() end

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function now(context)
    local ok, t = pcall(function() return statics:GetTimeSeconds(context) end)
    return ok and t or os.clock()
end

-- Cup positions, looked up once per level (searching every object is too slow to do often).
local function loadCups()
    if cups[1] ~= nil and valid(cups[1].actor) then return end
    cups = {}
    for _, cup in ipairs(FindAllOf("RGGolfCup") or {}) do
        if cup:IsValid() then
            local l = cup:K2_GetActorLocation()
            cups[#cups + 1] = { actor = cup, X = l.X, Y = l.Y, Z = l.Z }
        end
    end
end

local function nearestCup(p)
    local best, bestSq = nil, nil
    for _, cup in ipairs(cups) do
        local d = (cup.X - p.X) ^ 2 + (cup.Y - p.Y) ^ 2
        if bestSq == nil or d < bestSq then best, bestSq = cup, d end
    end
    return best
end

local function drop(ball, mesh, cup, at, speed)
    local dx, dy = cup.X - at.X, cup.Y - at.Y
    local len = math.max(math.sqrt(dx * dx + dy * dy), 1e-3)
    local keep = math.min(speed, DROP_SPEED)
    ball:K2_SetActorLocation(at, false, {}, true)
    mesh:SetPhysicsLinearVelocity({ X = dx / len * keep, Y = dy / len * keep, Z = -DROP_SPEED }, false, NONE)
end

local function step(entry, t)
    local ball = entry.ball
    local mesh = ball.StaticMesh
    local p = ball:K2_GetActorLocation()
    local v = mesh:GetPhysicsLinearVelocity(NONE)
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
    local last = entry.last or p
    entry.last = { X = p.X, Y = p.Y, Z = p.Z }
    entry.still = speed < 1 and entry.still + 1 or 0
    if entry.still > STILL_FRAMES or t - entry.started > MAX_SECONDS then return false end
    local cup = nearestCup(p)
    if cup == nil then return true end
    -- Fast balls cross the hole in a frame or two, so test the whole path since the last frame.
    local distance, at = Cup.closestApproach(last, p, cup)
    local onRim = at.Z > cup.Z - 2 and at.Z < cup.Z + BALL_RADIUS + RIM_BAND
    if distance < HOLE_RADIUS and onRim then
        if entry.over ~= cup then
            entry.over = cup
            local offset = Cup.closestApproach({ X = at.X - v.X, Y = at.Y - v.Y, Z = at.Z }, { X = at.X + v.X, Y = at.Y + v.Y, Z = at.Z }, cup)
            local limit = Cup.captureSpeed(offset, HOLE_RADIUS, CAPTURE_SPEED)
            if speed < limit then
                drop(ball, mesh, cup, at, speed)
                log(string.format("cup: dropped a ball crossing at %.0f cm/s, %.1f cm off centre (limit %.0f)", speed, offset, limit))
            else
                log(string.format("cup: ball too fast to drop, %.0f cm/s %.1f cm off centre (limit %.0f)", speed, offset, limit))
            end
        end
    elseif distance > HOLE_RADIUS + 5 then
        entry.over = nil
    end
    return true
end

-- Advances every tracked ball by one frame.
function Cup.update()
    if next(tracked) == nil then return end
    for key, entry in pairs(tracked) do
        local keep = enabled() and valid(entry.ball) and not entry.ball.BallIsInCup
        if keep then
            local ok, result = pcall(step, entry, now(entry.ball))
            keep = ok and result
            if not ok then log("cup: " .. tostring(result)) end
        end
        if not keep then tracked[key] = nil end
    end
end

-- Watch a ball that was just hit until it stops.
function Cup.track(ball)
    if not enabled() or not valid(ball) or not ball:HasAuthority() then return end
    loadCups()
    local key = ball:GetAddress()
    local entry = tracked[key]
    if entry ~= nil then
        entry.started, entry.still = now(ball), 0
        return
    end
    tracked[key] = { ball = ball, started = now(ball), still = 0 }
end

-- Looks up what the capture needs from the engine; Cup.start does this itself.
function Cup.init(isEnabled)
    enabled = isEnabled or enabled
    NONE = FName("None")
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
end

-- isEnabled: function returning whether the real putting setting is on.
function Cup.start(isEnabled)
    Cup.init(isEnabled)
    Golf.onHit(function(ball) Cup.track(ball) end)
    Loop.every(1, "cup", Cup.update)
end

return Cup
