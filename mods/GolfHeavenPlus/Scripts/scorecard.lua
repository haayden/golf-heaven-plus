-- Scorecard cleanup. The game's scorecard widget adds a row whenever a player joins, keyed by their
-- player state, but when a player leaves it only forgets the row; the row stays on screen. Someone
-- who leaves and rejoins gets a new player state, so every rejoin adds another row with the same
-- name. The game's own score data is right; this hides the rows it has forgotten.
local Loop = require("loop")

local Scorecard = {}

local WIDGET_CLASS = "/Game/Ride/UI/PlayerHUD/WG_ScoreCard.WG_ScoreCard_C"
local ROW_CLASS = "WG_ScoreCardRow_PlayerScore_C"
local COLLAPSED = 1          -- ESlateVisibility::Collapsed
local FRAMES_PER_UPDATE = 30 -- twice a second is plenty for a scorecard

local widgets = {} -- live scorecard widgets, collected as the game creates them

local function valid(object) return object ~= nil and object:IsValid() end

-- Live widgets sit under the transient package; the class templates don't.
local function remember(widget)
    if valid(widget) and widget:GetFullName():find("Transient", 1, true) then widgets[#widgets + 1] = widget end
end

local function tidy(widget)
    local kept = {}
    widget.LeaderboardEntries:ForEach(function(_, row)
        local r = row:get()
        if valid(r) then kept[r:GetAddress()] = true end
    end)
    local box = widget.VerticalBox_31
    for i = 0, box:GetChildrenCount() - 1 do
        local row = box:GetChildAt(i)
        if valid(row) and row:GetClass():GetFName():ToString() == ROW_CLASS and not kept[row:GetAddress()]
            and row:GetVisibility() ~= COLLAPSED then
            row:SetVisibility(COLLAPSED)
            local name = "?"
            pcall(function() name = row.PlayerStateToRepresent:GetPlayerName():ToString() end)
            print(string.format("[GolfHeavenPlus] scorecard: hid a leftover row (%s) from a player who left\n", name))
        end
    end
end

function Scorecard.update()
    for i = #widgets, 1, -1 do
        if valid(widgets[i]) then tidy(widgets[i]) else table.remove(widgets, i) end
    end
end

-- Watches for scorecards as the game creates them: searching every object is too slow to repeat.
function Scorecard.start()
    ExecuteInGameThread(function()
        LoadAsset(WIDGET_CLASS)
        NotifyOnNewObject(WIDGET_CLASS, remember)
        for _, widget in ipairs(FindAllOf("WG_ScoreCard_C") or {}) do remember(widget) end
    end)
    Loop.every(FRAMES_PER_UPDATE, "scorecard", Scorecard.update)
end

return Scorecard
