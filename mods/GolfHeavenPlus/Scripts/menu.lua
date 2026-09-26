-- The "Mods" sign on the main-menu signpost and the settings page it opens.
-- Every sign is a real WG_MainMenuButton_C that copies an existing sign's style, width and shadow,
-- so it looks like it shipped with the game.
local Loop = require("loop")

local Menu = {}

local MENU_CLASS = "/Game/Ride/Menu/WG_MainMenu.WG_MainMenu_C"
local BUTTON_CLASS = "/Game/Ride/Menu/WG_MainMenuButton.WG_MainMenuButton_C"
local PREFIX = "GHP_"
-- UE4SS keeps shared variables across mod reloads, so the original layout survives a hot reload
-- that happens while our signs are on screen.
local EXIT_PADDING_KEY = "GolfHeavenPlus.ExitPaddingTop"
local LIST_VISIBILITY_KEY = "GolfHeavenPlus.SignpostVisibility"

local COLLAPSED = 1
local MODS_ANGLE = 3.0
local SETTING_ANGLES = { 2.6, -3.1, 2.9, -2.7 }

local options = {}      -- { { key = "trajectory", label = "Trajectory" }, ... }
local getValue, toggleValue
local current = nil     -- everything we added to the live main menu
local actions = {}      -- button address -> click handler
local nameCounter = os.time() * 1000

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function log(message)
    print("[GolfHeavenPlus] " .. message .. "\n")
end

local function construct(className, outer, name)
    nameCounter = nameCounter + 1
    local fullName = string.format("%s%s_%d", PREFIX, name, nameCounter)
    return StaticConstructObject(StaticFindObject(className), outer, FName(fullName))
end

local function isOurs(widget)
    return valid(widget) and widget:GetFName():ToString():sub(1, #PREFIX) == PREFIX
end

local function margin(m)
    return { Left = m.Left, Top = m.Top, Right = m.Right, Bottom = m.Bottom }
end

local function copyTransform(t)
    return {
        Translation = { X = t.Translation.X, Y = t.Translation.Y },
        Scale = { X = t.Scale.X, Y = t.Scale.Y },
        Shear = { X = t.Shear.X, Y = t.Shear.Y },
        Angle = t.Angle,
    }
end

local function copyAlignedSlot(from, to)
    to:SetPadding(margin(from.Padding))
    to:SetHorizontalAlignment(from.HorizontalAlignment)
    to:SetVerticalAlignment(from.VerticalAlignment)
end

local function readVerticalSlot(slot)
    return {
        size = { SizeRule = slot.Size.SizeRule, Value = slot.Size.Value },
        padding = margin(slot.Padding),
        horizontal = slot.HorizontalAlignment,
        vertical = slot.VerticalAlignment,
    }
end

local function applyVerticalSlot(slot, saved)
    slot:SetSize(saved.size)
    slot:SetPadding(saved.padding)
    slot:SetHorizontalAlignment(saved.horizontal)
    slot:SetVerticalAlignment(saved.vertical)
end

-- UPanelWidget has no reflected InsertChildAt, so pull off everything from `index` on,
-- add the new child, and put the rest back with their original slot settings.
local function insertIntoVerticalBox(box, widget, index, saved)
    local tail = {}
    while box:GetChildrenCount() > index do
        local child = box:GetChildAt(index)
        tail[#tail + 1] = { widget = child, slot = readVerticalSlot(child.Slot) }
        box:RemoveChildAt(index)
    end
    applyVerticalSlot(box:AddChildToVerticalBox(widget), saved)
    for _, entry in ipairs(tail) do
        applyVerticalSlot(box:AddChildToVerticalBox(entry.widget), entry.slot)
    end
end

-- Removes our widgets from a panel; returns whether there were any.
local function removeOurs(panel)
    local found = false
    for i = panel:GetChildrenCount() - 1, 0, -1 do
        if isOurs(panel:GetChildAt(i)) then
            panel:RemoveChildAt(i)
            found = true
        end
    end
    return found
end

local function setLabel(button, text)
    button.DisplayText = FText(text)
    if valid(button.ButtonText) then button.ButtonText:SetText(FText(text)) end
end

local function labelFor(option)
    return string.format("%s: %s", option.label, getValue(option.key) and "On" or "Off")
end

local function copyImage(tree, template, name)
    local image = construct("/Script/UMG.Image", tree, name)
    image:SetBrush(template.Brush)
    image:SetRenderTransform(copyTransform(template.RenderTransform))
    return image
end

-- A sign: the template's drop shadow plus a new button in the template's style.
local function newSign(menu, template, text, angle)
    local tree = menu.WidgetTree
    local overlay = construct("/Script/UMG.Overlay", tree, "Sign")
    local templateShadow = template:GetParent():GetChildAt(0)
    copyAlignedSlot(templateShadow.Slot, overlay:AddChildToOverlay(copyImage(tree, templateShadow, "Shadow")))

    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local button = library:Create(menu, StaticFindObject(BUTTON_CLASS), menu:GetOwningPlayer())
    button:SetStyle(template.Style)
    button.ButtonWidth = template.ButtonWidth
    button:SetMinDimensions(template.MinWidth, template.MinHeight)
    button:SetMaxDimensions(template.MaxWidth, template.MaxHeight)
    local transform = copyTransform(template.RenderTransform)
    transform.Angle = angle
    button:SetRenderTransform(transform)
    setLabel(button, text)
    copyAlignedSlot(template.Slot, overlay:AddChildToOverlay(button))
    return overlay, button
end

-- The round no-smoking sign: a shadow and a ScaleBox holding the sign image.
local function copyNoSmokingSign(menu, original)
    local tree = menu.WidgetTree
    local overlay = construct("/Script/UMG.Overlay", tree, "NoSmoking")
    local shadowTemplate = original:GetChildAt(0)
    copyAlignedSlot(shadowTemplate.Slot, overlay:AddChildToOverlay(copyImage(tree, shadowTemplate, "Shadow")))

    local scaleTemplate = original:GetChildAt(1)
    local scale = construct("/Script/UMG.ScaleBox", tree, "Scale")
    scale:SetStretch(scaleTemplate.Stretch)
    scale:SetStretchDirection(scaleTemplate.StretchDirection)
    scale:SetUserSpecifiedScale(scaleTemplate.UserSpecifiedScale)
    copyAlignedSlot(scaleTemplate.Slot, overlay:AddChildToOverlay(scale))
    scale:AddChild(copyImage(tree, scaleTemplate:GetChildAt(0), "Image"))
    return overlay
end

local function showPage(entry, open)
    entry.list:SetVisibility(open and COLLAPSED or entry.visibility)
    entry.page:SetVisibility(open and entry.visibility or COLLAPSED)
    local focus = open and entry.firstSetting or entry.modsButton
    if valid(focus) then focus:SetFocus() end
end

-- Undo what an earlier copy of this mod did to this menu (UE4SS has no unload callback, so a
-- hot reload leaves our widgets in place), and remember the untouched layout for next time.
local function restoreOriginalLayout(list, column, exitSlot)
    local leftovers = removeOurs(list)
    leftovers = removeOurs(column) or leftovers
    if leftovers then
        local top = ModRef:GetSharedVariable(EXIT_PADDING_KEY)
        local visibility = ModRef:GetSharedVariable(LIST_VISIBILITY_KEY)
        if type(top) == "number" then exitSlot.padding.Top = top end
        if type(visibility) == "number" then list:SetVisibility(visibility) end
    end
    ModRef:SetSharedVariable(EXIT_PADDING_KEY, exitSlot.padding.Top)
    ModRef:SetSharedVariable(LIST_VISIBILITY_KEY, list:GetVisibility())
end

local function setup(menu)
    if current ~= nil and valid(current.menu) and current.menu:GetAddress() == menu:GetAddress() then return end
    local exitOverlay = menu.ExitButton:GetParent()
    local list = exitOverlay:GetParent()   -- the signpost: one overlay per sign
    local column = list:GetParent()
    local noSmoking = menu.Image_61:GetParent():GetParent()

    local exitSlot = readVerticalSlot(exitOverlay.Slot)
    restoreOriginalLayout(list, column, exitSlot)

    local entry = {
        menu = menu, list = list, column = column, exitOverlay = exitOverlay,
        visibility = list:GetVisibility(),
    }
    actions = {}

    -- Mods takes the bare stretch of post between the no-smoking sign and Exit, so the signpost
    -- keeps its height and Exit stays on screen.
    local signSlot = readVerticalSlot(list:GetChildAt(0).Slot)
    local modsOverlay, modsButton = newSign(menu, menu.JoinButton, "Mods", MODS_ANGLE)
    insertIntoVerticalBox(list, modsOverlay, list:GetChildIndex(exitOverlay), signSlot)
    local tightExit = margin(exitSlot.padding)
    tightExit.Top = 0
    exitOverlay.Slot:SetPadding(tightExit)
    entry.modsButton = modsButton

    -- Settings page: one sign per option, the no-smoking sign, and Back where Exit usually is.
    local page = construct("/Script/UMG.VerticalBox", menu.WidgetTree, "ModsPage")
    applyVerticalSlot(column:AddChildToVerticalBox(page), readVerticalSlot(list.Slot))
    page:SetVisibility(COLLAPSED)
    entry.page = page

    for i, option in ipairs(options) do
        local angle = SETTING_ANGLES[(i - 1) % #SETTING_ANGLES + 1]
        local overlay, button = newSign(menu, menu.OnlineSettings, labelFor(option), angle)
        applyVerticalSlot(page:AddChildToVerticalBox(overlay), signSlot)
        entry.firstSetting = entry.firstSetting or button
        actions[button:GetAddress()] = function()
            toggleValue(option.key)
            setLabel(button, labelFor(option))
        end
    end
    applyVerticalSlot(page:AddChildToVerticalBox(copyNoSmokingSign(menu, noSmoking)), readVerticalSlot(noSmoking.Slot))
    local backOverlay, backButton = newSign(menu, menu.ExitButton, "Back", menu.ExitButton.RenderTransform.Angle)
    local backSlot = readVerticalSlot(exitOverlay.Slot)
    applyVerticalSlot(page:AddChildToVerticalBox(backOverlay), backSlot)

    actions[modsButton:GetAddress()] = function() showPage(entry, true) end
    actions[backButton:GetAddress()] = function() showPage(entry, false) end

    current = entry
    log("Mods sign added to the main menu")
end

-- The menu's bound widgets exist right after construction, but its signs are only laid out a few
-- frames later. Wait until Exit has a real size before touching the signpost.
local function setupWhenReady(menu, triesLeft)
    if not valid(menu) or Loop.quitting() then return end
    local ready = valid(menu.ExitButton) and valid(menu.ExitButton:GetParent())
        and menu.ExitButton:GetDesiredSize().Y > 0
    if ready then
        local ok, err = pcall(setup, menu)
        if not ok then log("could not add the Mods sign: " .. tostring(err)) end
    elseif triesLeft > 0 then
        ExecuteInGameThreadWithDelay(100, function() setupWhenReady(menu, triesLeft - 1) end)
    end
end

-- config: { options = { {key, label}, ... }, get = function(key), toggle = function(key) }
function Menu.install(config)
    options, getValue, toggleValue = config.options, config.get, config.toggle

    NotifyOnNewObject(MENU_CLASS, function(menu)
        if menu:GetFName():ToString():find("^Default__") then return end
        ExecuteInGameThreadWithDelay(100, function() setupWhenReady(menu, 100) end)
    end)

    RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(context)
        local action = actions[context:get():GetAddress()]
        if action then action() end
    end)

    -- The mod can be (re)loaded while the main menu is already up.
    ExecuteInGameThread(function()
        for _, menu in ipairs(FindAllOf("WG_MainMenu_C") or {}) do
            if not menu:GetFName():ToString():find("^Default__") then setupWhenReady(menu, 100) end
        end
    end)
end

return Menu
