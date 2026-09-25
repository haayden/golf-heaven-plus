-- Everything that knows RV There Yet's golf classes lives here, so a game update only breaks this file.
-- All values below were read from the game's own shot logic (see docs/superpowers/specs).
local Golf = {}

local CLUB_CLASS = "/Game/Ride/Interactables/Golf/GolfClub/BP_Interactable_GolfClub.BP_Interactable_GolfClub_C"
local DEFAULT_GRAVITY_Z = -980
local SHOT_YAW_OFFSET = -90      -- golfers stand side-on: the ball leaves 90 degrees from where they face
local LAUNCH_LIFT = 4            -- the club launches from about 4 cm above the ball's origin
local MAX_REACH = 600            -- a ball further than this from the player isn't the one being addressed
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

-- The ball this club is lined up on, if the player is standing at it and it isn't already flying.
function Golf.addressedBall(club, pawn)
    local ball = club.ActorToHit
    if not valid(ball) or ball.GolfBallInFlight then return nil end
    local a, b = ball:K2_GetActorLocation(), pawn:K2_GetActorLocation()
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    if dx * dx + dy * dy + dz * dz > MAX_REACH * MAX_REACH then return nil end
    return ball
end

-- Power the next shot would use: the live meter while swinging, full power while lining up.
function Golf.power(club)
    local swing = club.RGGolfSwing
    if not valid(swing) then return 1, false end
    local stroke = swing.ActiveStroke
    local swinging = valid(stroke) and stroke:IsStrokeActive()
    if not swinging then return 1, false end
    local meter = swing.ReplicatedCurrentPower
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
        yaw = pawn:GetControlRotation().Yaw + SHOT_YAW_OFFSET,
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
