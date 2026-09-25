-- Dev-only shot recorder for Golf Heaven. It logs the game's own shot math (the club Blueprint's
-- CalculateLandLocation / SetNewTrajectory / ...) next to what the ball then really does, one
-- JSON object per shot in dev/golf-shots.jsonl. Used to build and check the trajectory preview.
local Probe = { shots = 0, status = "not started" }

local CLUB = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub.BP_Interactable_GolfClub_C"
local BALL = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfBall.BP_Interactable_GolfBall_C"
local SWING = "/Script/Ride.RGGolfSwingComponent"
local MANAGER = "/Script/Ride.RGGolfGameManager"

local CLUB_FUNCTIONS = {
    "ModSwingBasedOnHit", "ModPrecisionBasedOnClubCurves", "CalculateLandLocation", "SetNewTrajectory",
    "AdjustArcDependingOnTopSpin", "CalculateTiltOffset", "CalculateClubCarryDistance", "Local_GolfClubHit",
    "SimulateHit", "HitBall",
    "BndEvt__BP_Interactable_GolfClub_RGGolfSwing_K2Node_ComponentBoundEvent_0_OnSwingCompleted__DelegateSignature",
}
local CLUB_STATE = {
    "HitForce", "MaxDistance", "Arc Param", "DirectionalMultiplier", "SurfaceTypMultiplier",
    "TiltPitchOffset", "FollowThrough Hit Force", "UpdatedClubCondition", "SwingState",
}
local MAX_SAMPLE_SECONDS = 20

local logPath
local shot = nil          -- the shot being recorded
local sampler = nil       -- per-frame sampling handle

local function valid(object) return object ~= nil and object:IsValid() end

-- JSON --------------------------------------------------------------------------------------------
local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encode(value)
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.7g", value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "nil" then
        return "null"
    elseif kind == "table" then
        if value[1] ~= nil or next(value) == nil then
            local parts = {}
            for i, item in ipairs(value) do parts[i] = encode(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do parts[#parts + 1] = jsonString(key) .. ":" .. encode(value[key]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return jsonString(tostring(value))
end

local function appendLine(object)
    local file = io.open(logPath, "a")
    if not file then return end
    file:write(encode(object), "\n")
    file:close()
end

-- Unreal value helpers --------------------------------------------------------------------------
local function unwrap(param)
    local ok, value = pcall(function() return param:get() end)
    if ok then return value end
    return param
end

local function field(value, name)
    local ok, result = pcall(function() return value[name] end)
    if ok and type(result) == "number" then return result end
    return nil
end

-- Turns vectors, 2D vectors, rotators, objects and plain values into JSON-friendly data.
local function plain(value)
    local kind = type(value)
    if kind == "number" or kind == "boolean" or kind == "string" or kind == "nil" then return value end
    local x, y, z = field(value, "X"), field(value, "Y"), field(value, "Z")
    if x and y and z then return { x, y, z } end
    if x and y then return { x, y } end
    local pitch = field(value, "Pitch")
    if pitch then return { pitch = pitch, yaw = field(value, "Yaw"), roll = field(value, "Roll") } end
    local ok, name = pcall(function() return value:GetFName():ToString() end)
    if ok then return name end
    local okTag, tag = pcall(function() return value.TagName:ToString() end)
    if okTag then return tag end
    return tostring(value)
end

local function clubSnapshot(club)
    local state = {}
    for _, name in ipairs(CLUB_STATE) do
        local ok, value = pcall(function() return club[name] end)
        if ok then state[name] = plain(value) end
    end
    pcall(function()
        local swing = club.RGGolfSwing
        state.replicatedPower = swing.ReplicatedCurrentPower
        state.curvedReplicatedPower = swing:ApplyPowerCurve(swing.ReplicatedCurrentPower)
        state.strokeActive = swing.ActiveStroke:IsStrokeActive()
    end)
    local ok, player = pcall(function() return club.Player end)
    if ok and valid(player) then
        state.controlRotation = plain(player:GetControlRotation())
        local okCam, camera = pcall(function() return player.Controller.PlayerCameraManager end)
        if okCam and valid(camera) then
            state.cameraLocation = plain(camera:GetCameraLocation())
            state.cameraRotation = plain(camera:GetCameraRotation())
        end
    end
    return state
end

local function now(context)
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, seconds = pcall(function() return statics:GetTimeSeconds(context) end)
    if ok then return seconds end
    return os.clock()
end

local function gravityZ(actor)
    local ok, value = pcall(function() return actor:GetWorld():K2_GetWorldSettings().GlobalGravityZ end)
    if ok then return value end
    return nil
end

-- Recording --------------------------------------------------------------------------------------
local function finishShot(reason)
    if sampler ~= nil then CancelDelayedAction(sampler) sampler = nil end
    if shot == nil then return end
    shot.finished = reason
    appendLine(shot)
    Probe.shots = Probe.shots + 1
    print(string.format("[GolfProbe] shot %d recorded (%s, %d samples)\n", Probe.shots, reason, #shot.samples))
    shot = nil
end

local function newShot(context)
    if shot ~= nil then finishShot("replaced") end
    shot = { calls = {}, samples = {}, impacts = {}, started = now(context) }
    return shot
end

local function sampleBall(ball)
    if shot == nil or not valid(ball) then finishShot("ball gone") return end
    local mesh = ball.StaticMesh
    local t = now(ball)
    local location = ball:K2_GetActorLocation()
    local velocity = mesh:GetPhysicsLinearVelocity(FName("None"))
    shot.samples[#shot.samples + 1] = { t, location.X, location.Y, location.Z, velocity.X, velocity.Y, velocity.Z }
    local speed = math.sqrt(velocity.X ^ 2 + velocity.Y ^ 2 + velocity.Z ^ 2)
    shot.stillFrames = speed < 5 and (shot.stillFrames or 0) + 1 or 0
    if shot.stillFrames > 30 or t - shot.hit.t > MAX_SAMPLE_SECONDS then
        shot.final = { location.X, location.Y, location.Z }
        finishShot(shot.stillFrames > 30 and "stopped" or "timeout")
    end
end

local function hookClubFunction(name)
    RegisterHook(CLUB .. ":" .. name, function(context, ...)
        local club = context:get()
        local record = shot or newShot(club)
        local args = {}
        for i = 1, select("#", ...) do args[i] = plain(unwrap((select(i, ...)))) end
        record.calls[#record.calls + 1] = { fn = name, t = now(club), args = args }
        if name == "SetNewTrajectory" then
            record.club = club:GetClass():GetFName():ToString()
            record.clubState = clubSnapshot(club)
            -- Ask the club's own landing-spot function for comparison with the End it just used.
            local ball = club.CurrentHitActor
            if valid(ball) then
                local location = ball:K2_GetActorLocation()
                local asked = {}
                for _, withMultipliers in ipairs({ true, false }) do
                    local out = {}
                    local ok, err = pcall(function() club:CalculateLandLocation(location, withMultipliers, out) end)
                    asked[#asked + 1] = { with = withMultipliers, ok = ok, result = ok and plain(out) or tostring(err), raw = ok and plain(out.EndPosition) or nil }
                end
                record.askedLandLocation = asked
                local carry = {}
                pcall(function() club:CalculateClubCarryDistance(carry) end)
                record.askedCarry = plain(carry.ClubCarryDistanceInMeters) or plain(carry)
            end
        end
    end)
end

function Probe.start(devDir)
    logPath = devDir .. "/golf-shots.jsonl"
    for _, path in ipairs({ CLUB, BALL }) do LoadAsset(path) end

    RegisterHook(SWING .. ":HandleStrokeCompleted", function(context, power, precision, cleanHit)
        local swing = context:get()
        local record = newShot(swing)
        record.stroke = {
            power = unwrap(power), precision = plain(unwrap(precision)), cleanHit = plain(unwrap(cleanHit)),
            type = swing:GetActiveStrokeType(), owner = swing:GetOwner():GetClass():GetFName():ToString(),
            curvedPower = swing:ApplyPowerCurve(unwrap(power)), usesPowerCurve = swing.bUsePowerCurve,
        }
    end)

    for _, name in ipairs(CLUB_FUNCTIONS) do
        local ok, err = pcall(hookClubFunction, name)
        if not ok then print("[GolfProbe] could not hook " .. name .. ": " .. tostring(err) .. "\n") end
    end

    -- Live power while swinging: the last values before the hit go into the shot record.
    local lastPower = {}
    RegisterHook(SWING .. ":HandlePowerUpdated", function(context, power)
        local swing = context:get()
        local value = unwrap(power)
        lastPower.power = { value = value, curved = swing:ApplyPowerCurve(value), replicated = swing.ReplicatedCurrentPower, t = now(swing) }
    end)
    RegisterHook(SWING .. ":HandleDragUpdated", function(context, current, maxRegistered, precision)
        local swing = context:get()
        lastPower.drag = { current = unwrap(current), max = unwrap(maxRegistered), precision = unwrap(precision), replicated = swing.ReplicatedCurrentPower, t = now(swing) }
    end)

    RegisterHook(BALL .. ":OnHitByGolfClub", function(context, component, launchForce, impactOffset, instigator, localHit, spin, clubTag)
        local ball = context:get()
        local record = shot or newShot(ball)
        record.lastPower, lastPower = lastPower, {}
        local mesh = ball.StaticMesh
        local location = ball:K2_GetActorLocation()
        record.hit = {
            t = now(ball), ball = ball:GetFName():ToString(), start = plain(location),
            launchForce = plain(unwrap(launchForce)), impactOffset = plain(unwrap(impactOffset)),
            localHit = unwrap(localHit), clubTag = plain(unwrap(clubTag)),
            mass = mesh:GetMass(), linearDamping = mesh:GetLinearDamping(), angularDamping = mesh:GetAngularDamping(),
            gravityZ = gravityZ(ball),
        }
        local ok, spinTable = pcall(function()
            local s = unwrap(spin)
            return {
                backspin = plain(s.BackspinRange_6_79DBD784429CE5F8B38AFDA33185A43B),
                magnus = s.SidespinMagnusStrength_15_A0C5051046E5DDDF32FE8F9128EC2298,
            }
        end)
        if ok then record.hit.spin = spinTable end
        if sampler ~= nil then CancelDelayedAction(sampler) end
        sampler = LoopInGameThreadAfterFrames(1, function() sampleBall(ball) end)
    end)

    RegisterHook(BALL .. ":BndEvt__BP_Interactable_GolfBall_StaticMesh_K2Node_ComponentBoundEvent_1_ComponentHitSignature__DelegateSignature",
        function(context, hitComponent, otherActor, otherComponent, normalImpulse, hit)
            if shot == nil or shot.hit == nil or #shot.impacts >= 12 then return end
            local ball = context:get()
            local entry = { t = now(ball), location = plain(ball:K2_GetActorLocation()) }
            local ok, other = pcall(function() return unwrap(otherActor):GetFName():ToString() end)
            if ok then entry.other = other end
            local okHit, h = pcall(function() local r = unwrap(hit) return { plain(r.ImpactPoint), plain(r.ImpactNormal) } end)
            if okHit then entry.point, entry.normal = h[1], h[2] end
            shot.impacts[#shot.impacts + 1] = entry
        end)

    RegisterHook(MANAGER .. ":Multicast_OnGolfBallHit", function(context, owner, hitter, airDistance, totalDistance)
        appendLine({ event = "distances", air = unwrap(airDistance), total = unwrap(totalDistance) })
    end)

    Probe.status = "recording to " .. logPath
    print("[GolfProbe] " .. Probe.status .. "\n")
end

return Probe
