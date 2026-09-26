-- Backswing putting: how far the putter is drawn back sets how far the putt rolls, and the club
-- panel shows that distance while drawing back, so the same pull-back gives the same putt.
-- The game launches putts at 1.3-1.55x the putter head's speed at contact, so the distance comes
-- from how fast the mouse moves forward, which can't be repeated; it also counts a putter head
-- that is merely resting against the ball (dropped there by the click) as a stroke.
local Golf = require("golf")
local Loop = require("loop")

local Putt = {}

local FULL_DISTANCE = 2000       -- cm for a full backswing: the game's putter panel says "Max Distance 20 m"
local CURVE = 1.5                -- distance grows with backswing^1.5, so short putts get finer control
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
local enabled = function() return true end
local stroke = { live = false, depth = 0 } -- the local player's current putt
local last = nil                           -- distance in cm of the local player's last putt
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

-- Follows the local player's putter: a stroke starts when the head goes live and its depth is the
-- furthest the putter has been drawn back since.
function Putt.update()
    local putter = localPutter()
    local live = putter ~= nil and Golf.headLive(putter)
    if live and not stroke.live then stroke.depth = 0 end
    stroke.live = live
    if live then stroke.depth = math.max(stroke.depth, -Golf.puttDrag(putter)) end
end

-- What the club panel shows for the putter: the distance being drawn back for, or the last putt.
function Putt.status()
    if stroke.live then return { live = true, distance = Putt.distance(stroke.depth) } end
    return { live = false, distance = last }
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
    if currentDepth(putter) >= NO_BACKSWING then return end
    -- The click dropped the head onto the ball (or it crept there): cancel before it launches.
    head.PendingHit = nil
    log("putt: ignored the putter touching the ball before any backswing")
end

local function onHit(ball, putt, hitter)
    if not putt or not enabled() or not ball:HasAuthority() or not Golf.isLocal(hitter) then return end
    local putter = localPutter()
    if putter == nil then return end
    local distance = Putt.distance(currentDepth(putter))
    local speed = Putt.launchSpeed(distance)
    local mesh = ball.StaticMesh
    local launch = mesh:GetPhysicsLinearVelocity(NONE)
    local length = math.sqrt(launch.X ^ 2 + launch.Y ^ 2 + launch.Z ^ 2)
    if length < 1 or speed <= 0 then return end
    -- Keep the game's aim and hop angle; only the speed comes from the backswing.
    local k = speed / length
    mesh:SetPhysicsLinearVelocity({ X = launch.X * k, Y = launch.Y * k, Z = launch.Z * k }, false, NONE)
    if last ~= distance then log(string.format("putt: backswing %.0f%% -> %.1f m", currentDepth(putter) * 100, distance / 100)) end
    last = distance
end

-- isEnabled: function returning whether the real putting setting is on.
function Putt.start(isEnabled)
    enabled = isEnabled
    NONE = FName("None")
    Golf.onHit(onHit)
    Golf.onHeadTouch(onTouch)
    Loop.every(1, "putt", Putt.update)
end

return Putt
