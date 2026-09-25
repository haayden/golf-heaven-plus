-- Dev-only putter recorder. While the local player holds a putter it keeps the last few seconds
-- of golfer, putter-head and ball state, and whenever the putter touches a ball it saves those
-- seconds plus the next few (with the ball's spin) as one JSON line in dev/putter-watch.jsonl.
-- Kept light on purpose: no object searches per frame (FindAllOf scans every object and stutters);
-- the watched balls are the one under the crosshair and any the putter head touches.
local Watch = { saved = 0 }

local BALL = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfBall.BP_Interactable_GolfBall_C"
local CLUB = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub.BP_Interactable_GolfClub_C"
local PUTTER = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub_Putter.BP_Interactable_GolfClub_Putter_C"
local HEAD = "/Game/Ride/Interactables/Golf/GolfClub/BP_ClubHeadCollision.BP_ClubHeadCollision_C"

local BEFORE = 4        -- seconds kept before a touch
local AFTER = 4         -- seconds recorded after it
local FORGET = 800      -- cm: balls further than this from the golfer stop being watched
local MAX_BALLS = 4

local encode = require("json").encode
local logPath
local statics
local classes = {}
local controller = nil
local frames = {}       -- recent frames, oldest first
local events = {}       -- recent events, oldest first
local watched = {}      -- balls being sampled
local pendingSaves = {} -- { at = time to save, from = start time }

local function valid(object) return object ~= nil and object:IsValid() end

local function isA(object, path)
    if not valid(object) then return false end
    local class = classes[path]
    if not valid(class) then
        class = StaticFindObject(path)
        classes[path] = class
    end
    return valid(class) and object:IsA(class)
end

local function watch(ball)
    for _, b in ipairs(watched) do
        if b:GetAddress() == ball:GetAddress() then return end
    end
    if #watched >= MAX_BALLS then table.remove(watched, 1) end
    watched[#watched + 1] = ball
end

local function unwrap(param)
    local ok, value = pcall(function() return param:get() end)
    if ok then return value end
    return param
end

local function xyz(v) return { v.X, v.Y, v.Z } end

local function now(context)
    local ok, t = pcall(function() return statics:GetTimeSeconds(context) end)
    return ok and t or os.clock()
end

local function localController()
    if valid(controller) then return controller end
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if c:IsValid() and c:IsLocalController() then
            controller = c
            return c
        end
    end
    return nil
end

local function note(t, what, data)
    events[#events + 1] = { t = t, what = what, data = data }
end

local function trim(list, oldest, key)
    local drop = 0
    for _, item in ipairs(list) do
        if (key and item[key] or item[1]) < oldest then drop = drop + 1 else break end
    end
    for _ = 1, drop do table.remove(list, 1) end
end

local function save(from, to)
    local record = { frames = {}, events = {} }
    for _, f in ipairs(frames) do
        if f[1] >= from and f[1] <= to then record.frames[#record.frames + 1] = f end
    end
    for _, e in ipairs(events) do
        if e.t >= from and e.t <= to then record.events[#record.events + 1] = e end
    end
    local file = io.open(logPath, "a")
    if file then
        file:write(encode(record), "\n")
        file:close()
    end
    Watch.saved = Watch.saved + 1
    print(string.format("[PuttWatch] saved touch %d (%d frames, %d events)\n", Watch.saved, #record.frames, #record.events))
end

-- Something touched a ball: keep what led up to it and what follows.
local function touched(t, what, data)
    note(t, what, data)
    local last = pendingSaves[#pendingSaves]
    if last and t <= last.at then
        last.at = t + AFTER
    else
        pendingSaves[#pendingSaves + 1] = { at = t + AFTER, from = t - BEFORE }
    end
end

local function tick()
    local pc = localController()
    if pc == nil or not valid(pc.Pawn) then return end
    local pawn = pc.Pawn
    local t = now(pawn)
    for i = #pendingSaves, 1, -1 do
        local p = pendingSaves[i]
        if t >= p.at then
            save(p.from, p.at)
            table.remove(pendingSaves, i)
        end
    end
    local held = nil
    pcall(function() held = pawn:GetCurrentPickedUpActor() end)
    local putter = isA(held, PUTTER) and held or nil
    if putter == nil and #pendingSaves == 0 then
        frames, events, watched = {}, {}, {}
        return
    end
    local frame = { t }
    local l, r = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    frame.golfer = { l.X, l.Y, l.Z, r.Yaw, pc:GetControlRotation().Yaw, pawn.bUseControllerRotationYaw and 1 or 0 }
    if putter ~= nil then
        frame.head = xyz(putter.ClubHeadCollisionDummy:K2_GetComponentLocation())
        local proxy = putter.ClubHeadCollisionProxy
        if valid(proxy) then
            frame.proxy = xyz(proxy:K2_GetActorLocation())
            frame.proxyCollision = proxy.StaticMesh:GetCollisionEnabled()
            frame.proxyCheck = proxy.CheckHIt and 1 or 0
        end
        local swing = putter.RGGolfSwing
        local stroke = swing.ActiveStroke
        frame.swing = { putter.SwingState, valid(stroke) and stroke:IsStrokeActive() and 1 or 0, swing.ReplicatedCurrentPower }
        local looked = nil
        pcall(function() looked = pawn:GetCurrentLookedAtObject() end)
        if isA(looked, BALL) then watch(looked) end
    end
    frame.balls = {}
    for i = #watched, 1, -1 do
        local ball = watched[i]
        local keep = valid(ball)
        if keep then
            local b = ball:K2_GetActorLocation()
            keep = (b.X - l.X) ^ 2 + (b.Y - l.Y) ^ 2 < FORGET * FORGET
        end
        if not keep then table.remove(watched, i) end
    end
    for _, ball in ipairs(watched) do
        local mesh = ball.StaticMesh
        local v = mesh:GetPhysicsLinearVelocity(FName("None"))
        local w = mesh:GetPhysicsAngularVelocityInDegrees(FName("None"))
        local b = ball:K2_GetActorLocation()
        frame.balls[#frame.balls + 1] = { ball:GetFName():ToString(), b.X, b.Y, b.Z, v.X, v.Y, v.Z, w.X, w.Y, w.Z }
    end
    frames[#frames + 1] = frame
    trim(frames, t - BEFORE - AFTER - 1)
    trim(events, t - BEFORE - AFTER - 1, "t")
end

local function hook(path, fn, callback)
    local ok, err = pcall(function()
        RegisterHook(path .. ":" .. fn, function(context, ...)
            local okCall, errCall = pcall(callback, context:get(), ...)
            if not okCall then print("[PuttWatch] " .. fn .. ": " .. tostring(errCall) .. "\n") end
        end)
    end)
    if not ok then print("[PuttWatch] could not hook " .. fn .. ": " .. tostring(err) .. "\n") end
end

local function isBall(actor) return isA(actor, BALL) end

function Watch.start(devDir)
    if Watch.started then return "already running" end
    Watch.started = true
    logPath = devDir .. "/putter-watch.jsonl"
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    for _, path in ipairs({ BALL, CLUB, PUTTER, HEAD }) do pcall(LoadAsset, path) end

    hook(PUTTER, "SetClubheadCollisionEnabled", function(putter, enabled) note(now(putter), "Putter.SetClubheadCollisionEnabled", { enabled = unwrap(enabled) }) end)
    hook(PUTTER, "SpawnClubHeadCollisionProxy", function(putter) note(now(putter), "Putter.SpawnClubHeadCollisionProxy") end)
    hook(PUTTER, "RemoveClubHeadCollisionProxy", function(putter) note(now(putter), "Putter.RemoveClubHeadCollisionProxy") end)
    hook(CLUB, "ToggleFreeLook", function(club, active) note(now(club), "Club.ToggleFreeLook", { active = unwrap(active) }) end)
    hook(CLUB, "TryResetFromFreeLook", function(club) note(now(club), "Club.TryResetFromFreeLook") end)
    hook(HEAD, "PutBall", function(head, velocity)
        local target = head.ActorToHit
        if isBall(target) then watch(target) end
        touched(now(head), "Head.PutBall", { velocity = xyz(unwrap(velocity)), target = valid(target) and target:GetFName():ToString() or nil })
    end)
    hook(HEAD, "BndEvt__BP_ClubHeadCollision_StaticMesh_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature",
        function(head, component, other)
            local actor = unwrap(other)
            if isBall(actor) then
                watch(actor)
                touched(now(head), "Head.Overlap", { ball = actor:GetFName():ToString(), check = head.CheckHIt })
            end
        end)
    hook(BALL, "OnHitByGolfClub", function(ball, component, launch, offset, instigator, localHit)
        watch(ball)
        touched(now(ball), "Ball.OnHitByGolfClub", { ball = ball:GetFName():ToString(), launch = xyz(unwrap(launch)) })
    end)

    LoopInGameThreadAfterFrames(1, function()
        local ok, err = pcall(tick)
        if not ok then print("[PuttWatch] tick: " .. tostring(err) .. "\n") end
    end)
    print("[PuttWatch] recording to " .. logPath .. "\n")
    return "recording to " .. logPath
end

return Watch
