-- Golf Heaven Plus: entry point. Loads settings and starts each feature.
local Loop = require("loop")
local Config = require("config")
local Menu = require("menu")
local Preview = require("preview")
local Aim = require("aim")
local Cup = require("cup")
local Putt = require("putt")
local Readout = require("readout")
local Cart = require("cart")
local Scorecard = require("scorecard")

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]")
local CONFIG_PATH = MOD_DIR .. "/config.txt"

local settings = Config.load(CONFIG_PATH)

Loop.reset()

Menu.install({
    options = {
        { key = "trajectory", label = "Trajectory" },
        { key = "aim", label = "Aim Assist" },
        { key = "putting", label = "Real Putting" },
        { key = "cart", label = "Fast Cart" },
        { key = "tracer", label = "Shot Tracer" },
    },
    get = function(key) return settings[key] end,
    toggle = function(key)
        settings[key] = not settings[key]
        local ok, err = Config.save(CONFIG_PATH, settings)
        if not ok then print("[GolfHeavenPlus] could not save config.txt: " .. tostring(err) .. "\n") end
    end,
})

-- One feature failing to start shouldn't take the others down with it.
local function start(name, run)
    local ok, err = pcall(run)
    if not ok then print("[GolfHeavenPlus] " .. name .. " failed to start: " .. tostring(err) .. "\n") end
end

local function putting() return settings.putting end
start("trajectory", function() Preview.start(function() return settings.trajectory end) end)
start("aim assist", function() Aim.start(function() return settings.aim end) end)
start("cup capture", function() Cup.start(putting) end)
start("backswing putting", function() Putt.start(putting) end)
start("power readout", function() Readout.start(putting) end)
start("fast cart", function() Cart.start(function() return settings.cart end) end)
start("scorecard cleanup", function() Scorecard.start() end)

print("[GolfHeavenPlus] loaded\n")
