-- Everything that knows RV There Yet's golf classes lives here, so a game update only breaks this file.
-- All values below were read from the game's own shot logic (see docs/superpowers/specs).
local Golf = {}

local CLUB_CLASS = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub.BP_Interactable_GolfClub_C"
local BALL_CLASS = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfBall.BP_Interactable_GolfBall_C"
local DEFAULT_GRAVITY_Z = -980
local SHOT_YAW_OFFSET = -90      -- golfers stand side-on: the ball leaves 90 degrees from where they face
local LAUNCH_LIFT = 4            -- the club launches from about 4 cm above the ball's origin
local ADDRESS_REACH = 200        -- recorded hits all had the ball under 120 cm from the golfer; further can't be hit
local TRACE_VISIBILITY = 0       -- ETraceTypeQuery::TraceTypeQuery1 (Visibility)

local cache = {}

local function valid(object) return object ~= nil and object:IsValid() end

local function static(name, path)
    local object = cache[name]
    if not valid(object) then
        object = StaticFindObject(path)
        cache[name] = object
    end
    return object
end

function Golf.localController()
    local controller = cache.controller
    if valid(controller) then return controller end
    for _, candidate in ipairs(FindAllOf("PlayerController") or {}) do
        if candidate:IsValid() and candidate:IsLocalController() then
            cache.controller = candidate
            return candidate
        end
    end
    return nil
end

-- The club in the local player's hands, or nil.
function Golf.heldClub(pawn)
    local ok, held = pcall(function() return pawn:GetCurrentPickedUpActor() end)
    if not ok or not valid(held) then return nil end
    local clubClass = static("clubClass", CLUB_CLASS)
    if not valid(clubClass) or not held:IsA(clubClass) then return nil end
    return held
end

-- World yaw the shot will fly along: 90 degrees from the stance. Holding right-click to look
-- around (the club's free look) stops the body following the camera, so the body's facing is
-- the stance then; otherwise the aim is the control rotation, which the recorded shots match exactly.
function Golf.shotYaw(pawn, controller)
    local stance = controller:GetControlRotation().Yaw
    if not pawn.bUseControllerRotationYaw then stance = pawn:K2_GetActorRotation().Yaw end
    return stance + SHOT_YAW_OFFSET
end

-- A golf ball at rest within the player's reach.
local function hittable(ball, pawn)
    if not valid(ball) then return false end
    local ballClass = static("ballClass", BALL_CLASS)
    if not valid(ballClass) or not ball:IsA(ballClass) or ball.GolfBallInFlight then return false end
    local a, b = ball:K2_GetActorLocation(), pawn:K2_GetActorLocation()
    local dx, dy = a.X - b.X, a.Y - b.Y
    return dx * dx + dy * dy <= ADDRESS_REACH * ADDRESS_REACH
end

-- The ball the player is lining up: the one under their crosshair (the game's look-at target, the
-- ball it labels "Golf Ball"). The club's own ActorToHit can't be used: it only changes on contact,
-- so on the range it still names the last ball driven. Once picked, the ball stays picked while
-- the player free-looks (to check the hole) or the swing moves the camera, until they walk away
-- or it's hit. `last` is what this returned on the previous update.
function Golf.addressedBall(pawn, last)
    if pawn.bUseControllerRotationYaw then
        local ok, looked = pcall(function() return pawn:GetCurrentLookedAtObject() end)
        if ok and hittable(looked, pawn) then return looked end
    end
    if hittable(last, pawn) then return last end
    return nil
end

-- Power the next shot would use: the live meter while swinging, full power while lining up.
function Golf.power(club)
    local swing = club.RGGolfSwing
    if not valid(swing) then return 1, false end
    local stroke = swing.ActiveStroke
    local swinging = valid(stroke) and stroke:IsStrokeActive()
    if not swinging then return 1, false end
    -- Some swing types count as active from the moment the ball is addressed, with the meter
    -- still at zero: treat that as lining up and show the full-power shot.
    local meter = swing.ReplicatedCurrentPower
    if meter == nil or meter <= 0.001 then return 1, false end
    return swing:ApplyPowerCurve(meter), true
end

-- Everything the prediction needs for this club and ball, read live from the game.
function Golf.shot(club, ball, pawn)
    local mesh = ball.StaticMesh
    local location = ball:K2_GetActorLocation()
    local power, swinging = Golf.power(club)
    local lie = club.SurfaceTypMultiplier
    if lie == nil or lie <= 0 then lie = 1 end
    local gravity = DEFAULT_GRAVITY_Z
    local ok, worldGravity = pcall(function() return pawn:GetWorld():K2_GetWorldSettings().GlobalGravityZ end)
    if ok and type(worldGravity) == "number" and worldGravity ~= 0 then gravity = worldGravity end
    return {
        start = { X = location.X, Y = location.Y, Z = location.Z + LAUNCH_LIFT },
        yaw = Golf.shotYaw(pawn, pawn.Controller),
        distance = club.MaxDistance * club.DirectionalMultiplier * power * lie,
        arc = club["Arc Param"],
        gravityZ = gravity,
        damping = mesh:GetLinearDamping(),
        swinging = swinging,
        power = power,
    }
end

-- A hitTest for Trajectory.fly: line traces against the world, ignoring the golfer, club and ball.
function Golf.hitTest(worldContext, ignore)
    local kismet = static("kismet", "/Script/Engine.Default__KismetSystemLibrary")
    local color = { R = 0, G = 0, B = 0, A = 0 }
    return function(from, to)
        local hit = {}
        local blocked = kismet:LineTraceSingle(worldContext, from, to, TRACE_VISIBILITY, false, ignore, 0, hit, true, color, color, 0)
        if not blocked then return nil end
        local point, normal = hit.ImpactPoint, hit.ImpactNormal
        return {
            location = { X = point.X, Y = point.Y, Z = point.Z },
            normal = { X = normal.X, Y = normal.Y, Z = normal.Z },
        }
    end
end

function Golf.camera(controller)
    local manager = controller.PlayerCameraManager
    if not valid(manager) then return nil end
    return manager:GetCameraLocation()
end

return Golf
