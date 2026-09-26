-- Backswing putting: how far the putter is drawn back sets how far the putt rolls, and the club
-- panel shows that distance while drawing back, so the same pull-back gives the same putt.
-- The game launches putts at 1.3-1.55x the putter head's speed at contact, so the distance comes
-- from how fast the mouse moves forward, which can't be repeated; it also counts a putter head
-- that is merely resting against the ball (dropped there by the click) as a stroke.
local Golf = require("golf")
local Loop = require("loop")

local Putt = {}

local FULL_DISTANCE = 2000       -- cm for a full backswing: the game's putter panel says "Max Distance 20 m"
local CURVE = 2                  -- distance grows with backswing^2: short putts, the common ones, get
                                 -- most of the pull (1 m at 22%, 2 m at 32%, 5 m at 50%, 10 m at 71%)
local FIT_SCALE = 0.000595532    -- level putts in 45 recordings rolled 0.000596 * launch^2.147 cm
local FIT_POWER = 2.1474         -- (median error 9%), hop off the putter face included
local NO_BACKSWING = 0.01        -- less backswing than this is a touch, not a stroke

-- Distance in cm a backswing of `depth` (0-1) asks for.
function Putt.distance(depth)
    return FULL_DISTANCE * math.max(0, math.min(1, depth)) ^ CURVE
end

-- Launch speed in cm/s that rolls a putt `distance` cm on a level green.
function Putt.launchSpeed(distance)
    if distance <= 0 then return 0 end
    return (distance / FIT_SCALE) ^ (1 / FIT_POWER)
end

-- Runtime -----------------------------------------------------------------------------------------
local REPLACE_FRAMES = 10 -- how long after a putt to watch for the game's launch to land
local FLAT_BOOST = 1.067  -- the fit includes the game's hop, which carried ~15% of the distance
                          -- friction-free; a flat launch needs 1.15^(1/2.147) more speed
local AUTO_MIN_BACKSWING = 0.03 -- auto-putt only after a real backswing
local AUTO_TRIGGER = 0.08       -- forward movement from the deepest point that putts
local AUTO_WAIT_FRAMES = 30     -- frames to wait for the game to strike a handed-over ball
local DRAG_GAP = 3              -- seconds without a drag report that start another player's next stroke

local enabled = function() return true end
local aceOn = function() return false end  -- hole-in-one mode steers the local player's balls itself
local reported = {}                         -- player state address -> { depth, at }: other players'
                                            -- backswings, as their games report them to the host
-- The local player's current putt: how deep the backswing went, whether auto-putt has tried, frames
-- since it handed the ball to the head (nil if it hasn't), and whether the ball has been struck.
local stroke = { live = false, depth = 0, tried = false, waiting = nil, hit = false }
local last = nil                           -- distance in cm of the local player's last putt
local pending = {}                         -- ball address -> launch waiting to replace the game's
local NONE = nil

local function valid(object) return object ~= nil and object:IsValid() end

local function log(message) print("[GolfHeavenPlus] " .. message .. "\n") end

local function localPutter()
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.Pawn) then return nil end
    local club = Golf.heldClub(controller.Pawn)
    if club == nil or not Golf.isPutter(club) then return nil end
    return club
end

-- The game gives a putted ball its launch a frame after the hit; when it lands, swap in ours: the
-- backswing's speed along the same line, flat along the green (the game's 6 degree hop makes balls
-- float over holes). If the game applies its launch again, it gets replaced again. Only the machine
-- simulating the ball can change it (the host, in a hosted round); elsewhere the entry just expires.
local function replaceLaunches()
    for key, p in pairs(pending) do
        p.frames = p.frames + 1
        if not valid(p.ball) or p.frames > REPLACE_FRAMES then
            pending[key] = nil
        elseif Golf.simulatesHere(p.ball) then
            local mesh = p.ball.StaticMesh
            local v = mesh:GetPhysicsLinearVelocity(NONE)
            local speed = math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2)
            local ours = p.speed * FLAT_BOOST
            local games = math.abs(speed - p.gameSpeed) < 0.1 * p.gameSpeed
            local already = p.replaced and math.abs(speed - ours) < 0.1 * ours
            local flat = math.sqrt(v.X ^ 2 + v.Y ^ 2)
            if speed > 1 and games and not already and flat > 1e-3 then
                local k = ours / flat
                mesh:SetPhysicsLinearVelocity({ X = v.X * k, Y = v.Y * k, Z = 0 }, false, NONE)
                p.replaced = true
            end
        end
    end
end

-- Auto-putt: once the putter has been drawn back, the first push forward putts, so a soft
-- follow-through that would stop short of the ball still putts. The backswing sets the distance.
-- The ball is handed to the putter's head and the game strikes it on its own next tick.
local function autoPutt(putter, drag)
    if stroke.tried or stroke.hit or stroke.depth < AUTO_MIN_BACKSWING then return end
    if drag + stroke.depth < AUTO_TRIGGER then return end
    stroke.tried = true
    local controller = Golf.localController()
    if not valid(controller.PlayerState) then return end
    local ball = Golf.playerBall(controller.PlayerState)
    if ball == nil then return end -- no round (the driving range): putt by hand
    if not Golf.queuePutterHit(putter, ball, controller.Pawn) then
        log("auto-putt: your ball isn't at rest within reach")
        return
    end
    stroke.waiting = 0
    log(string.format("auto-putt: backswing %.0f%%, handed the ball to the putter", stroke.depth * 100))
end

-- Follows the local player's putter: a stroke starts when the head goes live and its depth is the
-- furthest the putter has been drawn back since.
function Putt.update()
    replaceLaunches()
    local putter = localPutter()
    local live = putter ~= nil and Golf.headLive(putter)
    if live and not stroke.live then stroke.depth, stroke.tried, stroke.waiting, stroke.hit = 0, false, nil, false end
    stroke.live = live
    if not live then return end
    local drag = Golf.puttDrag(putter)
    stroke.depth = math.max(stroke.depth, -drag)
    if not enabled() then return end
    autoPutt(putter, drag)
    if stroke.waiting ~= nil and not stroke.hit then
        stroke.waiting = stroke.waiting + 1
        if stroke.waiting == AUTO_WAIT_FRAMES then log("auto-putt: the game didn't strike the ball") end
    end
end

-- Backswing depth (0-1) that asks for `distance` cm: the inverse of Putt.distance.
function Putt.depthFor(distance)
    return math.max(0, math.min(1, distance / FULL_DISTANCE)) ^ (1 / CURVE)
end

-- What the displays show for the putter: the stroke being drawn back (live, depth, distance) and
-- the last putt's distance.
function Putt.status()
    return {
        live = stroke.live,
        depth = stroke.live and stroke.depth or 0,
        distance = stroke.live and Putt.distance(stroke.depth) or last,
        last = last,
    }
end

-- The local putter's backswing so far, including a stroke whose head went live this very frame.
local function currentDepth(putter)
    if stroke.live then return stroke.depth end
    return math.max(0, -Golf.puttDrag(putter))
end

local function onTouch(head, ball)
    if not enabled() then return end
    local putter = localPutter()
    if putter == nil or not valid(putter.ClubHeadCollisionProxy) then return end
    if putter.ClubHeadCollisionProxy:GetAddress() ~= head:GetAddress() then return end
    if stroke.hit then
        -- Already struck (auto-putt strikes before the head gets there): the head catching up
        -- with the rolling ball isn't a second stroke.
        head.PendingHit = nil
        return
    end
    if currentDepth(putter) >= NO_BACKSWING then return end
    -- The click dropped the head onto the ball (or it crept there): cancel before it launches.
    head.PendingHit = nil
    log("putt: ignored the putter touching the ball before any backswing")
end

local function playerName(playerState)
    local ok, name = pcall(function() return playerState:GetPlayerName():ToString() end)
    return ok and name or "?"
end

-- Queues the launch a putt with a backswing of `depth` should get, to replace the game's when it
-- lands. Returns the putt's distance, or nil if there's nothing to replace.
local function queueLaunch(ball, depth, launch, who)
    local distance = Putt.distance(depth)
    local speed = Putt.launchSpeed(distance)
    local gameSpeed = math.sqrt(launch.X ^ 2 + launch.Y ^ 2 + launch.Z ^ 2)
    if speed <= 0 or gameSpeed < 1 then return nil end
    local key = ball:GetAddress()
    if pending[key] == nil then
        log(string.format("putt%s: backswing %.0f%% -> %.1f m (game would have launched %.0f cm/s, now %.0f)",
            who, depth * 100, distance / 100, gameSpeed, speed))
    end
    pending[key] = { ball = ball, speed = speed, gameSpeed = gameSpeed, frames = 0 }
    return distance
end

local function onHit(ball, putt, hitter, launch)
    if not putt or not enabled() or not valid(hitter) then return end
    if Golf.isLocal(hitter) then
        stroke.hit = true -- struck, by the head or by auto-putt: nothing more this stroke
        local putter = localPutter()
        if putter == nil then return end
        local depth = currentDepth(putter)
        if aceOn() then
            last = Putt.distance(depth)
            return
        end
        last = queueLaunch(ball, depth, launch, "") or last
        return
    end
    -- Another player's putt: on the host, their game has been reporting their backswing here.
    local key = hitter:GetAddress()
    local drag = reported[key]
    reported[key] = nil
    if drag == nil or drag.depth <= 0 then return end
    queueLaunch(ball, drag.depth, launch, " (" .. playerName(hitter) .. ")")
end

-- Another player's drag meter, reported by their game to the host: remember how far back they drew.
local function onDrag(playerState, power)
    if type(power) ~= "number" or Golf.isLocal(playerState) then return end
    local key = playerState:GetAddress()
    local now = os.time()
    local drag = reported[key]
    if drag == nil or now - drag.at >= DRAG_GAP then
        drag = { depth = 0 }
        reported[key] = drag
    end
    drag.at = now
    if power < 0 then drag.depth = math.max(drag.depth, -power) end
end

-- isEnabled: function returning whether the real putting setting is on. isAceOn: function
-- returning whether hole-in-one mode is steering the local player's balls instead.
function Putt.start(isEnabled, isAceOn)
    enabled = isEnabled
    aceOn = isAceOn or aceOn
    NONE = FName("None")
    Golf.onHit(onHit)
    Golf.onHeadTouch(onTouch)
    Golf.onSwingDrag(onDrag)
    Loop.every(1, "putt", Putt.update)
end

return Putt
