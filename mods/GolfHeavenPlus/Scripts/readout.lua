-- Power readout: live swing power and how far it sends the ball, written into the game's own club
-- panel (the "Driver / Carry Distance / 150 m" box), and the last shot's numbers once it's hit, so a
-- shot can be repeated. For the putter it shows the distance the backswing is asking for.
local Golf = require("golf")
local Putt = require("putt")
local Loop = require("loop")

local Readout = {}

local FRAMES_PER_UPDATE = 3

local puttingEnabled = function() return true end
local lastShot = {} -- club class name -> { meter, carry } of the local player's last full swing
local live = nil    -- the local player's swing in progress: { class, meter, carry }

local function valid(object) return object ~= nil and object:IsValid() end

function Readout.metres(cm)
    local m = cm / 100
    if m < 10 then return string.format("%.1f m", m) end
    return string.format("%.0f m", m)
end

function Readout.percent(meter)
    return string.format("%d%%", math.floor(meter * 100 + 0.5))
end

-- Only writes when the text differs, so the game's own updates (e.g. on switching clubs) are
-- replaced at most once each.
local function setText(block, text)
    if not valid(block) then return end
    local ok, current = pcall(function() return block:GetText():ToString() end)
    if ok and current == text then return end
    block:SetText(FText(text))
end

local function lines(club)
    if Golf.isPutter(club) then
        if not puttingEnabled() then return nil end -- the game's own putting can't be predicted
        local status = Putt.status()
        if status.live then return "Backswing putt", Readout.metres(status.distance) end
        if status.distance then return "Last putt", Readout.metres(status.distance) end
        return nil
    end
    local power, swinging, meter = Golf.power(club)
    local class = club:GetClass():GetFName():ToString()
    if swinging then
        live = { class = class, meter = meter, carry = Golf.carry(club, power) }
        return "Power " .. Readout.percent(meter), Readout.metres(live.carry)
    end
    local shot = lastShot[class]
    if shot then return "Last " .. Readout.percent(shot.meter), Readout.metres(shot.carry) end
    return nil
end

function Readout.update()
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.Pawn) then return end
    local club = Golf.heldClub(controller.Pawn)
    if club == nil then
        live = nil
        return
    end
    local hud = club.CachedGolfHUD
    if not valid(hud) or not valid(hud.WG_GolfClubInfo) then return end
    local label, value = lines(club)
    if label == nil then return end
    setText(hud.WG_GolfClubInfo.SwingTypeText, label)
    setText(hud.WG_GolfClubInfo.CurrentClubMaxDistance, value)
end

-- A full swing by the local player just launched: its live numbers become that club's last shot.
local function onHit(ball, putt, hitter)
    if putt or live == nil or not Golf.isLocal(hitter) then return end
    lastShot[live.class] = live
    live = nil
end

-- isPuttingEnabled: function returning whether backswing putting (Real Putting) is on.
function Readout.start(isPuttingEnabled)
    puttingEnabled = isPuttingEnabled
    Golf.onHit(onHit)
    Loop.every(FRAMES_PER_UPDATE, "readout", Readout.update)
end

return Readout
