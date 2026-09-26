-- Hole-in-one mode, the host's secret (F6 toggles it): the local player's balls steer themselves
-- into the current hole's cup. What a ball does depends on whether it can see the cup:
--   * on the ground with a clear line: roll straight in when close, else chip in on an arc;
--   * on the ground behind cover (a bunker's lip, a wall) or stuck: pop straight up, higher each time;
--   * in the air with a clear line: keep its arc, re-aiming sideways every frame to come down on the cup;
--   * in the air behind cover: fly on untouched until the cup comes into view;
--   * close to the cup: head for the inside of it.
-- Only the machine that simulates a ball can steer it, which in a hosted round is the host, so
-- guests can't turn it on.
local Golf = require("golf")
local Loop = require("loop")
local Cup = require("cup")

local Ace = {}

local ROLL_DECEL = 323   -- cm/s²: how hard a green slows a rolling ball (measured from putts)
local ARRIVE_SPEED = 90  -- cm/s left when a rolling ball reaches the cup, slow enough to drop
local ROLL_RANGE = 3000  -- cm: closer than this on the ground, with a clear line, the ball rolls in
local ROLL_RISE = 150    -- cm: ...if the cup is no more than this above or below it
local LOB_MIN_TIME, LOB_MAX_TIME = 1.2, 4 -- seconds a chip hangs in the air, longer for longer chips
local POP_SPEED = 1500   -- cm/s straight up out of cover, half again more each further pop
local POP_SIDE = 200     -- cm/s towards the cup while popping up
local MAX_EXTRA_POPS = 4 -- pops beyond this don't go any higher
local LAUNCH_PAUSE = 0.3 -- seconds after a pop or chip before the ground can launch it again
local STUCK_FRAMES = 20  -- frames on the ground without moving that count as stuck behind something
local AIR_GAIN = 0.35    -- share of the gap to the right sideways velocity closed each frame in the air
local MIN_FALL = 0.15    -- seconds: closer to coming down than this, the air leaves the ball alone
local MAX_AIR_SPEED = 8000 -- cm/s: the fastest the air re-aims a ball sideways (a drive is ~7000)
local GROUND_TRACE = 10  -- cm below the ball's centre that counts as touching the ground
local SIGHT_HEIGHT = 30  -- cm above the cup the line of sight aims at
local SIGHT_MARGIN = 100 -- cm: something this close to the cup (the flag) doesn't block the line
local DUNK_RADIUS = 90   -- cm: this close to the cup (and no higher above it) the ball heads into it
local DUNK_SPEED = 180   -- cm/s
local DUNK_DEPTH = 10    -- cm below the cup's rim the ball aims for
local TELEPORT = 500     -- cm moved in one frame: the game put the ball back (water, out of bounds)
local MAX_SECONDS = 30
local GRAVITY = 980

local on = false
local homing = {} -- ball address -> { ball, cup, hitTest, started, last, still, pops, launchedAt }
local NONE, statics = nil, nil

local function valid(object) return object ~= nil and object:IsValid() end

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function now(context)
    local ok, t = pcall(function() return statics:GetTimeSeconds(context) end)
    return ok and t or os.time()
end

function Ace.isOn() return on end

-- The velocity that takes a ball at `p` moving at `v` towards the cup `c` this frame (see the
-- header), or nil to leave the ball alone. grounded: it's touching the ground. clear: nothing
-- stands between it and the cup. pops: how often it has already been popped out of cover. The
-- second result says "pop" or "chip" when the ball is being launched off the ground.
-- Pure maths, for the tests.
function Ace.steer(p, v, c, grounded, clear, pops)
    local dx, dy, dz = c.X - p.X, c.Y - p.Y, c.Z - p.Z
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < DUNK_RADIUS and -dz < DUNK_RADIUS then
        local tz = dz - DUNK_DEPTH
        local len = math.max(math.sqrt(dx * dx + dy * dy + tz * tz), 1)
        return { X = dx / len * DUNK_SPEED, Y = dy / len * DUNK_SPEED, Z = tz / len * DUNK_SPEED }
    end
    local ux, uy = dx / math.max(dist, 1), dy / math.max(dist, 1)
    if grounded then
        if not clear then
            return { X = ux * POP_SIDE, Y = uy * POP_SIDE, Z = POP_SPEED * (1 + 0.5 * math.min(pops or 0, MAX_EXTRA_POPS)) }, "pop"
        end
        if dist < ROLL_RANGE and math.abs(dz) < ROLL_RISE then
            local speed = math.sqrt(2 * ROLL_DECEL * dist + ARRIVE_SPEED * ARRIVE_SPEED)
            return { X = ux * speed, Y = uy * speed, Z = v.Z }
        end
        local t = math.max(LOB_MIN_TIME, math.min(LOB_MAX_TIME, 1 + dist / 5000))
        return { X = dx / t, Y = dy / t, Z = (dz + 0.5 * GRAVITY * t * t) / t }, "chip"
    end
    if not clear then return nil end
    -- Seconds until the ball comes down to the cup's height. None (or almost none) left means it is
    -- below the cup, or about to be: leave it to land, and the ground launches it from there.
    local reach = v.Z * v.Z - 2 * GRAVITY * dz
    if reach < 0 then return nil end
    local fall = (v.Z + math.sqrt(reach)) / GRAVITY
    if fall < MIN_FALL then return nil end
    local wantX, wantY = dx / fall, dy / fall
    local speed = math.sqrt(wantX * wantX + wantY * wantY)
    if speed > MAX_AIR_SPEED then wantX, wantY = wantX * MAX_AIR_SPEED / speed, wantY * MAX_AIR_SPEED / speed end
    return { X = v.X + (wantX - v.X) * AIR_GAIN, Y = v.Y + (wantY - v.Y) * AIR_GAIN, Z = v.Z }
end

-- Whether nothing but the flag stands between the ball and the cup.
local function canSee(entry, p)
    local c = entry.cup
    local hit = entry.hitTest({ X = p.X, Y = p.Y, Z = p.Z + 5 }, { X = c.X, Y = c.Y, Z = c.Z + SIGHT_HEIGHT })
    if hit == nil then return true end
    local h = hit.location
    return (h.X - c.X) ^ 2 + (h.Y - c.Y) ^ 2 < SIGHT_MARGIN ^ 2
end

-- One frame for one ball; false once it's done (in the cup, reset by the game, or given up on).
local function step(entry)
    local ball = entry.ball
    local t = now(ball)
    if ball.BallIsInCup or t - entry.started > MAX_SECONDS then return false end
    local p = ball:K2_GetActorLocation()
    local last = entry.last
    entry.last = { X = p.X, Y = p.Y, Z = p.Z }
    if last ~= nil then
        local movedSq = (p.X - last.X) ^ 2 + (p.Y - last.Y) ^ 2 + (p.Z - last.Z) ^ 2
        if movedSq > TELEPORT ^ 2 then return false end
        entry.still = movedSq < 0.25 and entry.still + 1 or 0
    end
    if not Golf.simulatesHere(ball) then return true end
    local grounded = entry.hitTest(p, { X = p.X, Y = p.Y, Z = p.Z - GROUND_TRACE }) ~= nil
    if grounded and entry.launchedAt ~= nil and t - entry.launchedAt < LAUNCH_PAUSE then return true end
    local clear = canSee(entry, p) and not (grounded and entry.still > STUCK_FRAMES)
    local mesh = ball.StaticMesh
    local want, launch = Ace.steer(p, mesh:GetPhysicsLinearVelocity(NONE), entry.cup, grounded, clear, entry.pops)
    if want == nil then return true end
    if launch ~= nil then
        entry.launchedAt, entry.still = t, 0
        if launch == "pop" then entry.pops = entry.pops + 1 end
    end
    mesh:SetPhysicsLinearVelocity(want, false, NONE)
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
    local pawn = Golf.localController().Pawn
    homing[key] = {
        ball = ball, cup = { X = cup.X, Y = cup.Y, Z = cup.Z }, hitTest = Golf.hitTest(ball, { ball, pawn }),
        started = now(ball), still = 0, pops = 0,
    }
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
