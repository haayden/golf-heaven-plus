-- Aim assist: swing the aim around the ball instead of shuffling your feet to line up.
-- While a ball is lined up, turning with the mouse walks the golfer around it so it stays in
-- front of them, and each scroll-wheel notch nudges the aim a degree (also while holding
-- right-click to look down the fairway). Walking or swinging leaves everything to the game.
local Golf = require("golf")
local Loop = require("loop")

local Aim = {}

local WHEEL_STEP = 1 -- degrees of aim per scroll notch; scrolling up swings the shot to the right
local MAX_TURN = 45  -- a bigger jump between frames is a respawn or a camera reset, not aiming

local enabled = function() return true end
local keys = nil
local addressed = nil
local lastYaw = nil

local function valid(object) return object ~= nil and object:IsValid() end

-- `point` swung `degrees` of yaw around `pivot` (both {X, Y, Z}); its height is kept.
function Aim.orbit(point, pivot, degrees)
    local r = math.rad(degrees)
    local c, s = math.cos(r), math.sin(r)
    local dx, dy = point.X - pivot.X, point.Y - pivot.Y
    return { X = pivot.X + dx * c - dy * s, Y = pivot.Y + dx * s + dy * c, Z = point.Z }
end

-- Signed smallest turn from yaw `from` to yaw `to`, in degrees.
function Aim.turn(from, to)
    local d = (to - from) % 360
    if d > 180 then d = d - 360 end
    return d
end

local function scrolled(controller)
    keys = keys or { up = { KeyName = FName("MouseScrollUp") }, down = { KeyName = FName("MouseScrollDown") } }
    if controller:WasInputKeyJustPressed(keys.up) then return 1 end
    if controller:WasInputKeyJustPressed(keys.down) then return -1 end
    return 0
end

local function walking(pawn)
    local input = pawn.CharacterMovement:GetLastInputVector()
    return input.X * input.X + input.Y * input.Y > 0.01
end

-- Turns the golfer's stance and walks them around the ball in the same frame, so nothing (a
-- putter head included) ever swings past the ball on the way.
local function nudge(controller, pawn, ball, degrees)
    local r = pawn:K2_GetActorRotation()
    local around = Aim.orbit(pawn:K2_GetActorLocation(), ball:K2_GetActorLocation(), degrees)
    pawn:K2_SetActorLocationAndRotation(around, { Pitch = r.Pitch, Yaw = r.Yaw + degrees, Roll = r.Roll }, true, {}, false)
    if pawn.bUseControllerRotationYaw then
        local c = controller:GetControlRotation()
        controller:SetControlRotation({ Pitch = c.Pitch, Yaw = c.Yaw + degrees, Roll = c.Roll })
    end
    lastYaw = r.Yaw + degrees -- already walked around; nothing left for the next tick to follow
end

local function tick()
    local controller = Golf.localController()
    if not enabled() or not valid(controller) or not valid(controller.Pawn) then
        lastYaw = nil
        return
    end
    local pawn = controller.Pawn
    local yaw = pawn:K2_GetActorRotation().Yaw
    local turned = lastYaw and Aim.turn(lastYaw, yaw) or 0
    lastYaw = yaw
    local club = Golf.heldClub(pawn)
    if club == nil then
        addressed = nil
        return
    end
    addressed = Golf.addressedBall(pawn, addressed)
    if addressed == nil or walking(pawn) then return end
    local _, swinging = Golf.power(club)
    if swinging then return end
    -- A putter's head is live from the click until the stroke ends; moving the golfer then would
    -- drag it into the ball, and the game counts any touch as a stroke. Aim only with it lifted.
    if Golf.isPutter(club) and Golf.headLive(club) then return end

    if turned ~= 0 and math.abs(turned) < MAX_TURN then
        local around = Aim.orbit(pawn:K2_GetActorLocation(), addressed:K2_GetActorLocation(), turned)
        pawn:K2_SetActorLocation(around, true, {}, false)
    end
    local notches = scrolled(controller)
    if notches ~= 0 then nudge(controller, pawn, addressed, notches * WHEEL_STEP) end
end

-- isEnabled: function returning whether the aim assist setting is on.
function Aim.start(isEnabled)
    enabled = isEnabled
    Loop.every(1, "aim", function()
        local ok, err = pcall(tick)
        if not ok then
            lastYaw = nil
            error(err, 0)
        end
    end)
end

return Aim
