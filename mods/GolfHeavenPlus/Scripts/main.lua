-- Golf Heaven Plus: entry point. Loads settings and starts each feature.
local Config = require("config")
local Menu = require("menu")
local Preview = require("preview")
local Aim = require("aim")
local Cup = require("cup")

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]")
local CONFIG_PATH = MOD_DIR .. "/config.txt"

local settings = Config.load(CONFIG_PATH)

Menu.install({
    options = {
        { key = "trajectory", label = "Trajectory" },
        { key = "aim", label = "Aim Assist" },
        { key = "putting", label = "Real Putting" },
        { key = "tracer", label = "Shot Tracer" },
    },
    get = function(key) return settings[key] end,
    toggle = function(key)
        settings[key] = not settings[key]
        local ok, err = Config.save(CONFIG_PATH, settings)
        if not ok then print("[GolfHeavenPlus] could not save config.txt: " .. tostring(err) .. "\n") end
    end,
})

Preview.start(function() return settings.trajectory end)
Aim.start(function() return settings.aim end)
Cup.start(function() return settings.putting end)

print("[GolfHeavenPlus] loaded\n")
