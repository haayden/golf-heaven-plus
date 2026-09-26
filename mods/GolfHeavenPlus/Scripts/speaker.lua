-- Speaker: a JBL-style speaker that plays YouTube links, louder the closer you stand to it.
-- Copy a YouTube link and press F8: the speaker appears in front of you and plays it, with the
-- song's title floating above it. F7 picks it up (it floats in front of you) and puts it down again
-- where you are; F9 stops the music. The game can't decode audio itself (no media players ship
-- with it), so the music comes from mpv + yt-dlp in tools/mpv, started hidden and driven over its
-- IPC pipe. Only this player sees and hears it.
local Golf = require("golf")
local Loop = require("loop")

local Speaker = {}

local PIPE = "\\\\.\\pipe\\ghp-speaker"
local FULL_VOLUME = 300     -- cm: full volume this close to the speaker
local SILENT = 4000         -- cm: silent this far away
local HEARTBEAT = 3         -- seconds between "the game is still running" messages to mpv
local LAUNCH_WAIT = 10      -- seconds to wait for mpv's pipe after starting it
local CARRY = { forward = 60, down = 35 } -- where a carried speaker floats, from the camera
local LENGTH, DIAMETER = 22, 10           -- cm
local BODY_COLOR = { R = 0.02, G = 0.02, B = 0.025, A = 1 }
local CAP_COLOR = { R = 0.9, G = 0.25, B = 0.02, A = 1 } -- the orange ends of a JBL speaker
local LABEL_HEIGHT = 16     -- cm above the speaker
local FRAMES_PER_UPDATE = 5

local MESH = "/Engine/BasicShapes/Cylinder.Cylinder"
local MATERIAL = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local MOVABLE, NO_COLLISION = 2, 0

local mpvExe, statusPath = nil, nil
local speaker = nil  -- { body, caps = {a, b}, label, position, yaw, carried }
local queue = {}     -- JSON lines waiting for mpv's pipe
local launchedAt, lastBeat, lastVolume, lastStatus, lastStatusCheck = nil, 0, nil, nil, nil
local NONE = nil

local function valid(object) return object ~= nil and object:IsValid() end
local function log(message) print("[GolfHeavenPlus] speaker: " .. message .. "\n") end

-- mpv ---------------------------------------------------------------------------------------------
local function command(...)
    local parts = {}
    for i, value in ipairs({ ... }) do
        parts[i] = type(value) == "number" and tostring(value) or ('"' .. tostring(value):gsub('[\\"]', "\\%0") .. '"')
    end
    queue[#queue + 1] = '{"command":[' .. table.concat(parts, ",") .. "]}\n"
end

-- Sends what's queued; starts mpv (hidden: it has no window with this config) if its pipe isn't up.
local function flush()
    if #queue == 0 then return end
    local pipe = io.open(PIPE, "w")
    if pipe then
        for _, line in ipairs(queue) do pipe:write(line) end
        pipe:close()
        queue = {}
        return
    end
    if launchedAt == nil or os.time() - launchedAt > LAUNCH_WAIT then
        if launchedAt ~= nil then log("mpv didn't start; trying again") end
        launchedAt = os.time()
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LaunchURL(mpvExe)
    end
end

local function readStatus()
    local file = io.open(statusPath, "r")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

-- The speaker model ------------------------------------------------------------------------------
local function spawnPart(world, color)
    local actor = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    actor:SetReplicates(false)
    local component = actor.StaticMeshComponent
    component:SetMobility(MOVABLE)
    component:SetStaticMesh(StaticFindObject(MESH))
    component:SetCollisionEnabled(NO_COLLISION)
    local material = component:CreateDynamicMaterialInstance(0, StaticFindObject(MATERIAL), NONE)
    if valid(material) then material:SetVectorParameterValue(FName("Color"), color) end
    return actor
end

local function spawnLabel(world)
    local actor = world:SpawnActor(StaticFindObject("/Script/Engine.TextRenderActor"), { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    actor:SetReplicates(false)
    local text = actor.TextRender
    text:SetHorizontalAlignment(1) -- EHTA_Center
    text:SetWorldSize(5)
    text:SetTextRenderColor({ R = 255, G = 255, B = 255, A = 255 })
    text:SetText(FText(""))
    return actor
end

-- Lays the speaker on its side at position, pointing along yaw.
local function pose()
    local p, yaw = speaker.position, speaker.yaw
    local math3d = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local rotation = { Pitch = 90, Yaw = yaw, Roll = 0 }
    local axis = math3d:GetUpVector(rotation)
    local d = DIAMETER / 100
    speaker.body:K2_SetActorLocationAndRotation(p, rotation, false, {}, true)
    speaker.body:SetActorScale3D({ X = d, Y = d, Z = LENGTH / 100 })
    for i, cap in ipairs(speaker.caps) do
        local side = (i == 1 and 1 or -1) * (LENGTH / 2)
        cap:K2_SetActorLocationAndRotation({ X = p.X + axis.X * side, Y = p.Y + axis.Y * side, Z = p.Z + axis.Z * side }, rotation, false, {}, true)
        cap:SetActorScale3D({ X = d * 1.08, Y = d * 1.08, Z = 0.012 })
    end
end

local function camera()
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.PlayerCameraManager) then return nil end
    local manager = controller.PlayerCameraManager
    return manager:GetCameraLocation(), manager:GetCameraRotation()
end

-- Where the speaker lands if dropped now: on the ground a little in front of the player.
local function groundInFront()
    local location, rotation = camera()
    if location == nil then return nil end
    local yaw = math.rad(rotation.Yaw)
    local ahead = { X = location.X + math.cos(yaw) * 120, Y = location.Y + math.sin(yaw) * 120, Z = location.Z }
    local controller = Golf.localController()
    local hit = Golf.hitTest(controller.Pawn, { controller.Pawn })(ahead, { X = ahead.X, Y = ahead.Y, Z = ahead.Z - 1000 })
    if hit == nil then return nil end
    local l = hit.location
    return { X = l.X, Y = l.Y, Z = l.Z + DIAMETER / 2 }, rotation.Yaw + 90
end

local function ensureSpeaker()
    if speaker ~= nil and valid(speaker.body) then return true end
    local controller = Golf.localController()
    if not valid(controller) or not valid(controller.Pawn) then return false end
    local position, yaw = groundInFront()
    if position == nil then return false end
    local world = controller.Pawn:GetWorld()
    speaker = {
        body = spawnPart(world, BODY_COLOR),
        caps = { spawnPart(world, CAP_COLOR), spawnPart(world, CAP_COLOR) },
        label = spawnLabel(world),
        position = position, yaw = yaw, carried = false,
    }
    pose()
    return true
end

-- Keys --------------------------------------------------------------------------------------------
local function playClipboard()
    if not ensureSpeaker() then return end
    command("script-message", "ghp-heartbeat")
    command("script-message", "ghp-play-clipboard")
    lastVolume = nil
end

local function toggleCarry()
    if not ensureSpeaker() then return end
    if speaker.carried then
        local position, yaw = groundInFront()
        if position then speaker.position, speaker.yaw = position, yaw end
        speaker.carried = false
        pose()
    else
        speaker.carried = true
    end
end

local function stop()
    if launchedAt ~= nil then command("script-message", "ghp-stop") end
end

-- Every few frames ---------------------------------------------------------------------------------
function Speaker.update()
    flush()
    if speaker == nil or not valid(speaker.body) then return end
    local location, rotation = camera()
    if location == nil then return end
    if speaker.carried then
        local yaw, pitch = math.rad(rotation.Yaw), math.rad(rotation.Pitch)
        local f = { X = math.cos(pitch) * math.cos(yaw), Y = math.cos(pitch) * math.sin(yaw), Z = math.sin(pitch) }
        speaker.position = { X = location.X + f.X * CARRY.forward, Y = location.Y + f.Y * CARRY.forward, Z = location.Z + f.Z * CARRY.forward - CARRY.down }
        speaker.yaw = rotation.Yaw + 90
        pose()
    end
    local p = speaker.position
    speaker.label:K2_SetActorLocationAndRotation({ X = p.X, Y = p.Y, Z = p.Z + LABEL_HEIGHT }, { Pitch = 0, Yaw = rotation.Yaw + 180, Roll = 0 }, false, {}, true)

    if launchedAt == nil then return end
    if os.time() - lastBeat >= HEARTBEAT then
        lastBeat = os.time()
        command("script-message", "ghp-heartbeat")
    end
    local d = math.sqrt((p.X - location.X) ^ 2 + (p.Y - location.Y) ^ 2 + (p.Z - location.Z) ^ 2)
    local volume = math.floor(100 * math.max(0, math.min(1, (SILENT - d) / (SILENT - FULL_VOLUME))) ^ 2 + 0.5)
    if lastVolume == nil or math.abs(volume - lastVolume) >= 2 then
        lastVolume = volume
        command("set_property", "volume", volume)
    end
    if os.time() == lastStatusCheck then return end
    lastStatusCheck = os.time()
    local status = readStatus()
    if status ~= nil and status ~= lastStatus then
        lastStatus = status
        local shown = status:gsub("^playing: ", "\226\153\170 "):sub(1, 60) -- "♪ Title"
        speaker.label.TextRender:SetText(FText(shown))
        log(status)
    end
end

-- modDir: the mod's folder (holding tools/mpv).
function Speaker.start(modDir)
    NONE = FName("None")
    local tools = modDir:gsub("/", "\\") .. "\\tools\\mpv"
    mpvExe = tools .. "\\mpv.exe"
    statusPath = tools .. "\\portable_config\\speaker-status.txt"
    local exe = io.open(mpvExe, "rb")
    if not exe then
        log("tools/mpv/mpv.exe is missing, so the speaker is off")
        return
    end
    exe:close()
    RegisterKeyBind(Key.F8, function() ExecuteInGameThread(Speaker.playClipboard) end)
    RegisterKeyBind(Key.F7, function() ExecuteInGameThread(Speaker.toggleCarry) end)
    RegisterKeyBind(Key.F9, function() ExecuteInGameThread(Speaker.stop) end)
    Loop.every(FRAMES_PER_UPDATE, "speaker", Speaker.update)
end

-- What the keys do, also callable from the dev harness.
Speaker.playClipboard, Speaker.toggleCarry, Speaker.stop = playClipboard, toggleCarry, stop

-- Starts mpv (if needed) without playing anything: sends a heartbeat. For checking the launch.
function Speaker.wake() command("script-message", "ghp-heartbeat") end

return Speaker
