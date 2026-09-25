-- RVDump: dev-only helper, not shipped.
-- At the main menu it force-loads the golf and menu Blueprints (they normally only load
-- inside Golf Heaven), writes UE4SS's reflection dumps, and saves the live widget tree
-- of the main menu. Type `rvdump` in the console to run it again, e.g. inside Golf Heaven.

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]")
local SDK_DIR = SCRIPT_DIR .. "/../../../sdk"

local ASSETS = {
    -- Golf gameplay
    "/Game/Ride/Golf/BP_GolfGameManager",
    "/Game/Ride/Golf/BP_GolfHole",
    "/Game/Ride/Golf/BP_GolfCup",
    "/Game/Ride/Golf/BP_GolfCupDrivingRange",
    "/Game/Ride/Golf/BP_GolfDrivingRangeTee",
    "/Game/Ride/Golf/BP_GolfWorldRangeTee",
    "/Game/Ride/Golf/BP_PuttingGreenGolfBallSpawner",
    "/Game/Ride/Golf/E_GolfTeeShapes",
    "/Game/Ride/Golf/E_Golf_ShotValuedInGreatness",
    "/Game/Ride/Golf/E_Golf_Terms",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_ClubHeadCollision",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_GolfBallMarker",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_GolfTee",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfBall",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Driver",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_EmilsLegendaryVeryLegalWedgePutter",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Iron5",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Iron7",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Putter",
    "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Wedge",
    "/Game/Ride/Interactables/Golf/GolfClub/FC_HorizontalSpin",
    "/Game/Ride/Interactables/Golf/GolfClub/FC_HorizontalSpin_Driver",
    "/Game/Ride/Interactables/Golf/GolfClub/FC_VerticalSpin",
    "/Game/Ride/Interactables/Golf/GolfClub/FC_VerticalSpin_Driver",
    "/Game/Ride/Interactables/Golf/GolfClub/FGolfBallSpinValues",
    "/Game/Ride/Interactables/GolfFlag/BP_Interactable_GolfFlag",
    "/Game/Ride/GolfCart/BP_GolfCart",
    -- Golf HUD
    "/Game/Ride/UI/PlayerHUD/WG_GolfClubInfo",
    "/Game/Ride/UI/PlayerHUD/WG_GolfSwing",
    "/Game/Ride/UI/PlayerHUD/WG_GolfSwingMeter",
    "/Game/Ride/UI/PlayerHUD/WG_GolfSwingMeter_Target",
    "/Game/Ride/UI/PlayerHUD/WG_GolfSwingMeter_TargetHoldSteady",
    "/Game/Ride/UI/PlayerHUD/WG_PlayerGolfBallIndicator",
    "/Game/Ride/UI/PlayerHUD/WG_PlayerGolfFlagIndicator",
    "/Game/Ride/UI/PlayerHUD/WG_ScoreCard",
    -- Front end
    "/Game/Ride/Menu/WG_MainMenu",
    "/Game/Ride/Menu/WG_MainMenuButton",
    "/Game/Ride/Menu/WG_SignButton",
    "/Game/Ride/Menu/WG_MenuButton",
    "/Game/Ride/Menu/W_FrontEnd",
    "/Game/Ride/Menu/WG_NewGame",
    "/Game/Ride/Menu/WG_OptionMenu",
    "/Game/Ride/Menu/WG_OptionEntryStepper",
    "/Game/Ride/Menu/WG_PopupGeneric",
    "/Game/Ride/Menu/BP_FrontEndController",
}

local function log(fmt, ...)
    print(string.format("[RVDump] " .. fmt .. "\n", ...))
end

local function loadAssets()
    local loaded, missing = 0, {}
    for _, path in ipairs(ASSETS) do
        local name = path:match("([^/]+)$")
        local ok = false
        for _, candidate in ipairs({ path .. "." .. name .. "_C", path .. "." .. name }) do
            local success, obj = pcall(LoadAsset, candidate)
            if success and obj ~= nil and obj:IsValid() then
                ok = true
                break
            end
        end
        if ok then loaded = loaded + 1 else missing[#missing + 1] = path end
    end
    log("loaded %d/%d assets", loaded, #ASSETS)
    for _, path in ipairs(missing) do log("  could not load %s", path) end
end

local function describe(widget, classes)
    local text = widget:GetClass():GetFName():ToString() .. " '" .. widget:GetFName():ToString() .. "'"
    if widget:IsA(classes.TextBlock) then
        local ok, value = pcall(function() return widget:GetText():ToString() end)
        if ok then text = text .. ' text="' .. value .. '"' end
    end
    local ok, visibility = pcall(function() return widget:GetVisibility() end)
    if ok then text = text .. " vis=" .. tostring(visibility) end
    return text
end

local function walkWidget(widget, depth, classes, out)
    if widget == nil or not widget:IsValid() then return end
    out[#out + 1] = string.rep("  ", depth) .. describe(widget, classes)
    if widget:IsA(classes.UserWidget) then
        local tree = widget.WidgetTree
        if tree:IsValid() then walkWidget(tree.RootWidget, depth + 1, classes, out) end
    elseif widget:IsA(classes.PanelWidget) then
        for i = 0, widget:GetChildrenCount() - 1 do
            walkWidget(widget:GetChildAt(i), depth + 1, classes, out)
        end
    end
end

local function dumpMainMenuTree()
    local classes = {
        UserWidget = StaticFindObject("/Script/UMG.UserWidget"),
        PanelWidget = StaticFindObject("/Script/UMG.PanelWidget"),
        TextBlock = StaticFindObject("/Script/UMG.TextBlock"),
    }
    local out = {}
    for _, menu in ipairs(FindAllOf("WG_MainMenu_C") or {}) do
        out[#out + 1] = "== " .. menu:GetFullName()
        walkWidget(menu, 0, classes, out)
    end
    local file = io.open(SDK_DIR .. "/MainMenuTree.txt", "w")
    if file == nil then
        log("could not write %s/MainMenuTree.txt", SDK_DIR)
        return
    end
    file:write(table.concat(out, "\n"), "\n")
    file:close()
    log("wrote MainMenuTree.txt (%d lines)", #out)
end

local function runDump()
    log("starting dump")
    loadAssets()
    dumpMainMenuTree()
    DumpAllObjects()
    log("object dump done")
    GenerateSDK()
    log("CXX headers done")
    DumpJMAP()
    log("jmap done")
    GenerateLuaTypes()
    log("lua types done")
    log("finished")
end

local dumpedThisSession = false
NotifyOnNewObject("/Game/Ride/Menu/WG_MainMenu.WG_MainMenu_C", function()
    if dumpedThisSession then return true end
    dumpedThisSession = true
    ExecuteInGameThreadWithDelay(8000, runDump)
    return true
end)

RegisterConsoleCommandHandler("rvdump", function()
    runDump()
    return true
end)

log("loaded; sdk dir = %s", SDK_DIR)
