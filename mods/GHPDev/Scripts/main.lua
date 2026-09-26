-- GHPDev: dev-only remote control for the running game. Never shipped.
-- tools/ghp.sh writes "<id>\n<command>" to dev/cmd.txt. This mod runs each new id once and
-- writes "<id>\n<output>" to dev/out.txt. Commands:
--   ping                 -> pong
--   restart <ModName>    -> RestartMod
--   console <command>    -> runs a UE console command as the local player
--   lua <code>           -> runs Lua in this mod's state; print() and return values are captured
--   test                 -> runs mods/GolfHeavenPlus/Scripts/tests.lua with fresh module copies
--   probe                -> status of the golf shot recorder (dev/golf-shots.jsonl)

local GolfProbe = require("golfprobe")
local PuttWatch = require("puttwatch")

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]")
local MODS_DIR = SCRIPT_DIR .. "/../.."
local DEV_DIR = MODS_DIR .. "/../dev"
local CMD_FILE = DEV_DIR .. "/cmd.txt"
local OUT_FILE = DEV_DIR .. "/out.txt"

-- Scratch space that survives between `lua` commands.
S = S or {}

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function writeFile(path, text)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(text)
    file:close()
    return true
end

local function joinValues(first, last, ...)
    local parts = {}
    for i = first, last do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, "\t")
end

local function localPlayerController()
    for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
        if controller:IsValid() and controller:IsLocalController() then return controller end
    end
    return nil
end

local function runLua(code)
    local output = {}
    local env = setmetatable({
        print = function(...) output[#output + 1] = joinValues(1, select("#", ...), ...) end,
    }, { __index = _G })
    local chunk, err = load(code, "=ghp", "t", env)
    if not chunk then return "ERROR " .. tostring(err) end
    local results = table.pack(pcall(chunk))
    if not results[1] then
        output[#output + 1] = "ERROR " .. tostring(results[2])
    elseif results.n > 1 then
        output[#output + 1] = joinValues(2, results.n, table.unpack(results, 1, results.n))
    end
    return table.concat(output, "\n")
end

local function runConsole(command)
    local controller = localPlayerController()
    if controller == nil then return "ERROR no local player controller" end
    local kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    kismet:ExecuteConsoleCommand(controller, command, controller)
    return "ok"
end

local function runTests()
    local scripts = MODS_DIR .. "/GolfHeavenPlus/Scripts"
    local loadedBefore = {}
    for name in pairs(package.loaded) do loadedBefore[name] = true end
    local oldPath = package.path
    package.path = scripts .. "/?.lua;" .. oldPath
    local ok, report = pcall(dofile, scripts .. "/tests.lua")
    package.path = oldPath
    for name in pairs(package.loaded) do
        if not loadedBefore[name] then package.loaded[name] = nil end
    end
    if not ok then return "ERROR " .. tostring(report) end
    return tostring(report)
end

-- Restarting a mod while UE4SS is running one of its loops crashes the game inside UE4SS. Mods that
-- watch "<Name>.Quit" (GolfHeavenPlus does) cancel their loops first; give them time to.
local QUIT_GRACE_MS = 500

local function restartMod(name)
    ModRef:SetSharedVariable(name .. ".Quit", true)
    ExecuteInGameThreadWithDelay(QUIT_GRACE_MS, function() RestartMod(name) end)
    return string.format("stopping %s's loops, restarting it in %d ms", name, QUIT_GRACE_MS)
end

local function dispatch(command)
    local verb, rest = command:match("^%s*(%S+)%s*(.-)%s*$")
    if verb == "ping" then return "pong" end
    if verb == "restart" then return restartMod(rest) end
    if verb == "console" then return runConsole(rest) end
    if verb == "lua" then return runLua(rest) end
    if verb == "test" then return runTests() end
    if verb == "probe" then return string.format("%s, %d shots", GolfProbe.status, GolfProbe.shots) end
    return "ERROR unknown command: " .. tostring(verb)
end

local function readCommand()
    local text = readFile(CMD_FILE)
    if text == nil then return nil end
    return text:match("^([^\r\n]+)\r?\n(.*)$")
end

-- Don't replay whatever command was left over from the last session.
local lastId = readCommand()

LoopInGameThreadWithDelay(250, function()
    local id, command = readCommand()
    if id == nil or id == lastId then return end
    lastId = id
    local ok, result = pcall(dispatch, command)
    if not ok then result = "ERROR " .. tostring(result) end
    writeFile(OUT_FILE, id .. "\n" .. tostring(result) .. "\n")
end)

-- The shot and putter recorders hook the game's golf functions (PutBall, OnHitByGolfClub, the ball's
-- every bounce) and sample every frame. A PutBall called from Lua crashed the game inside PuttWatch's
-- hook, so they stay off while Hayden plays; switch on only for a recording session.
local RECORDERS = false

if RECORDERS then
    ExecuteInGameThread(function()
        local ok, err = pcall(GolfProbe.start, DEV_DIR)
        if not ok then
            GolfProbe.status = "failed: " .. tostring(err)
            print("[GolfProbe] " .. GolfProbe.status .. "\n")
        end
        local okWatch, errWatch = pcall(PuttWatch.start, DEV_DIR)
        if not okWatch then print("[PuttWatch] failed: " .. tostring(errWatch) .. "\n") end
    end)
end

print("[GHPDev] listening on " .. CMD_FILE .. "\n")
