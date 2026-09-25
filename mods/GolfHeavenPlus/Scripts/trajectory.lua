-- Shot prediction math, mirroring what RV There Yet does (verified against 19 recorded shots):
--   * the club picks a landing spot `distance` away at the ball's height, where
--     distance = MaxDistance * DirectionalMultiplier * ActualPower * lie multiplier;
--   * it launches with UGameplayStatics::SuggestProjectileVelocity_CustomArc toward that spot;
--   * the ball then flies under gravity with the physics body's linear damping.
-- No Unreal calls here, so it can be unit-tested; collision comes in through `hitTest`.
local Trajectory = {}

local function length(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- Landing spot for a shot fired along `yawDegrees` (world yaw), level with `start`.
function Trajectory.target(start, yawDegrees, distance)
    local yaw = math.rad(yawDegrees)
    return { X = start.X + math.cos(yaw) * distance, Y = start.Y + math.sin(yaw) * distance, Z = start.Z }
end

-- Port of UGameplayStatics::SuggestProjectileVelocity_CustomArc. `arc` 0 = straight up,
-- 1 = straight at the target. Returns nil when no arc reaches the target.
function Trajectory.launchVelocity(start, target, arc, gravityZ)
    local dx, dy, dz = target.X - start.X, target.Y - start.Y, target.Z - start.Z
    local distance = length(dx, dy, dz)
    if distance < 1e-4 then return nil end
    -- Lerp(UpVector, StartToEndDir, arc), normalized
    local lx, ly, lz = dx / distance * arc, dy / distance * arc, (1 - arc) + dz / distance * arc
    local size = length(lx, ly, lz)
    if size < 1e-8 then return nil end
    lx, ly, lz = lx / size, ly / size, lz / size
    local angle = math.asin(math.max(-1, math.min(1, lz)))
    local horizontal = math.sqrt(dx * dx + dy * dy)
    local denominator = (dz - horizontal * math.tan(angle)) * math.cos(angle) ^ 2
    if denominator == 0 then return nil end
    local inside = (gravityZ * horizontal * horizontal * 0.5) / denominator
    if inside < 0 then return nil end
    local speed = math.sqrt(inside)
    return { X = lx * speed, Y = ly * speed, Z = lz * speed }
end

-- Exact position at time t for constant gravity plus linear damping k (dv/dt = g - k v).
function Trajectory.positionAt(start, velocity, gravityZ, damping, t)
    local drift -- integral of e^(-k s) ds from 0 to t
    if damping < 1e-9 then drift = t else drift = (1 - math.exp(-damping * t)) / damping end
    local x = start.X + velocity.X * drift
    local y = start.Y + velocity.Y * drift
    local z
    if damping < 1e-9 then
        z = start.Z + velocity.Z * t + 0.5 * gravityZ * t * t
    else
        local terminal = gravityZ / damping
        z = start.Z + terminal * t + (velocity.Z - terminal) * drift
    end
    return { X = x, Y = y, Z = z }
end

-- Samples the flight every `step` seconds and asks `hitTest(from, to)` about each segment.
-- hitTest returns nil or { location = {X,Y,Z}, normal = {X,Y,Z} }.
-- Returns { points = { ... up to and including the landing spot }, landing = hit or nil }.
function Trajectory.fly(start, velocity, options)
    local points = { start }
    local previous = start
    local t = 0
    while t < options.maxTime do
        t = t + options.step
        local current = Trajectory.positionAt(start, velocity, options.gravityZ, options.damping, t)
        local hit = options.hitTest(previous, current)
        if hit then
            points[#points + 1] = hit.location
            return { points = points, landing = hit }
        end
        points[#points + 1] = current
        previous = current
    end
    return { points = points, landing = nil }
end

return Trajectory
