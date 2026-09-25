-- In-game unit tests for Golf Heaven Plus's pure modules. Run with: tools/ghp.sh test
local passed, failures = 0, {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = name .. ": " .. tostring(err)
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
    end
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local Config = require("config")
local TEMP_FILE = (os.getenv("TEMP") or ".") .. "/ghp_config_test.txt"

test("parse reads booleans in several spellings", function()
    local v = Config.parse("a=true\nb=off\nc = 1\nd=NO\ne=Yes\n")
    eq(v.a, true, "a")
    eq(v.b, false, "b")
    eq(v.c, true, "c")
    eq(v.d, false, "d")
    eq(v.e, true, "e")
end)

test("parse skips comments, blank and malformed lines", function()
    local v = Config.parse("# comment\n\n  name =  hello world  \nnot a pair\r\n#x=1\n")
    eq(v.name, "hello world", "name")
    eq(count(v), 1, "key count")
end)

test("serialize sorts keys and round-trips", function()
    local original = { tracer = false, trajectory = true, label = "x" }
    local text = Config.serialize(original)
    eq(text, "label=x\ntracer=false\ntrajectory=true\n", "text")
    local back = Config.parse(text)
    eq(count(back), 3, "key count")
    for k, v in pairs(original) do eq(back[k], v, k) end
end)

test("load fills missing keys from defaults", function()
    assert(Config.save(TEMP_FILE, { tracer = false }))
    local v = Config.load(TEMP_FILE)
    eq(v.tracer, false, "tracer")
    eq(v.trajectory, Config.DEFAULTS.trajectory, "trajectory")
    os.remove(TEMP_FILE)
end)

test("load of a missing file returns a copy of the defaults", function()
    os.remove(TEMP_FILE)
    local v = Config.load(TEMP_FILE)
    for k, default in pairs(Config.DEFAULTS) do eq(v[k], default, k) end
    v.trajectory = not v.trajectory
    eq(Config.load(TEMP_FILE).trajectory, Config.DEFAULTS.trajectory, "defaults untouched")
end)

local Render = require("render")

local function near(actual, expected, what, tolerance)
    if math.abs(actual - expected) > (tolerance or 1e-6) then
        error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
    end
end

local function point(x, y, z) return { X = x, Y = y, Z = z } end

test("resample spaces points evenly along a straight path", function()
    local points = Render.resample({ point(0, 0, 0), point(10, 0, 0) }, 2)
    eq(#points, 6, "count")
    for i, p in ipairs(points) do near(p.X, (i - 1) * 2, "x" .. i) end
end)

test("resample keeps spacing across corners", function()
    local points = Render.resample({ point(0, 0, 0), point(3, 0, 0), point(3, 3, 0) }, 2)
    eq(#points, 4, "count")
    near(points[2].X, 2, "p2.x")
    near(points[3].X, 3, "p3.x")
    near(points[3].Y, 1, "p3.y")
    near(points[4].Y, 3, "p4.y")
end)

test("resample survives empty paths and repeated points", function()
    eq(#Render.resample({}, 5), 0, "empty")
    local points = Render.resample({ point(0, 0, 0), point(0, 0, 0), point(4, 0, 0) }, 2)
    eq(#points, 3, "count")
    near(points[3].X, 4, "last")
end)

local function distance(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

test("adaptive resample is dense near the viewer and sparse far away", function()
    local viewer = point(0, 0, 100)
    local points = Render.resampleAdaptive({ point(0, 0, 0), point(20000, 0, 0) }, viewer, 0.1, 2, 200)
    near(points[1].X, 0, "starts at the path start")
    near(points[#points].X, 20000, "ends at the path end")
    -- The final step is whatever is left to reach the end, so compare the full steps before it.
    local first, late = points[2].X - points[1].X, points[#points - 1].X - points[#points - 2].X
    assert(first < 15, "first step " .. first)
    assert(late > 1000, "late step " .. late)
    for i = 2, #points - 2 do
        local step = distance(points[i], points[i + 1])
        local expected = math.max(2, 0.1 * distance(points[i], viewer))
        near(step, expected, "step " .. i, 1e-6)
    end
end)

test("adaptive resample widens its steps to stay under the point budget", function()
    local points = Render.resampleAdaptive({ point(0, 0, 0), point(20000, 0, 0) }, point(0, 0, 100), 0.01, 1, 30)
    assert(#points <= 30, "count " .. #points)
    near(points[#points].X, 20000, "still reaches the end")
end)

test("adaptive resample follows corners and survives short paths", function()
    local points = Render.resampleAdaptive({ point(0, 0, 0), point(10, 0, 0), point(10, 10, 0) }, point(0, 0, 0), 0, 3, 100)
    for _, p in ipairs(points) do assert(p.Y < 1e-9 or math.abs(p.X - 10) < 1e-9, "off path") end
    near(points[#points].Y, 10, "end")
    eq(#Render.resampleAdaptive({}, point(0, 0, 0), 0.1, 1, 10), 0, "empty")
    eq(#Render.resampleAdaptive({ point(1, 1, 1) }, point(0, 0, 0), 0.1, 1, 10), 1, "single")
end)

-- Rotates v by the quaternion q the way FQuat::RotateVector does.
local function rotate(q, v)
    local tx, ty, tz = 2 * (q.Y * v.Z - q.Z * v.Y), 2 * (q.Z * v.X - q.X * v.Z), 2 * (q.X * v.Y - q.Y * v.X)
    return point(v.X + q.W * tx + (q.Y * tz - q.Z * ty), v.Y + q.W * ty + (q.Z * tx - q.X * tz), v.Z + q.W * tz + (q.X * ty - q.Y * tx))
end

test("segment transform lays the cylinder's axis from a to b", function()
    for _, case in ipairs({
        { point(0, 0, 0), point(0, 0, 50) }, { point(0, 0, 0), point(30, 0, 0) },
        { point(5, -3, 2), point(-7, 11, -4) }, { point(0, 0, 10), point(0, 0, -10) },
    }) do
        local a, b = case[1], case[2]
        local t = Render.segmentTransform(a, b, 4)
        local axis = rotate(t.Rotation, point(0, 0, 1))
        local length = distance(a, b)
        near(axis.X, (b.X - a.X) / length, "axis x", 1e-9)
        near(axis.Y, (b.Y - a.Y) / length, "axis y", 1e-9)
        near(axis.Z, (b.Z - a.Z) / length, "axis z", 1e-9)
        near(t.Translation.X, (a.X + b.X) / 2, "mid x")
        near(t.Scale3D.X, 0.04, "width")
        near(t.Scale3D.Z, (length + 4) / 100, "length overlaps the joints")
    end
    eq(Render.segmentTransform(point(1, 1, 1), point(1, 1, 1), 4), nil, "zero length")
end)

local Aim = require("aim")

test("orbit keeps the ball at the same spot relative to the golfer", function()
    local ball, golfer = point(100, 200, 0), point(100, 140, 88)
    local moved = Aim.orbit(golfer, ball, 90)
    near(moved.X, 160, "x")
    near(moved.Y, 200, "y")
    near(moved.Z, 88, "height unchanged")
    local back = Aim.orbit(moved, ball, -90)
    near(back.X, golfer.X, "round trip x")
    near(back.Y, golfer.Y, "round trip y")
end)

test("turn is the signed smallest difference between two yaws", function()
    near(Aim.turn(10, 30), 20, "plain")
    near(Aim.turn(350, 10), 20, "across 360")
    near(Aim.turn(10, 350), -20, "backwards across 360")
    near(Aim.turn(-170, 170), -20, "negative yaws")
end)

local Trajectory = require("trajectory")

test("launchVelocity reproduces the game's launch for a recorded driver shot", function()
    -- Shot logged in Golf Heaven: SetNewTrajectory(start, end, 0.7) -> LaunchForce
    local v = Trajectory.launchVelocity(point(-22252.48, 34456.4, 2296.488), point(-18705.59, 37294.81, 2296.488), 0.7, -980)
    near(v.X, 1779.395, "x", 0.05)
    near(v.Y, 1423.966, "y", 0.05)
    near(v.Z, 976.7224, "z", 0.05)
end)

test("launchVelocity has no answer for zero distance", function()
    eq(Trajectory.launchVelocity(point(1, 2, 3), point(1, 2, 3), 0.5, -980), nil, "velocity")
end)

test("target points along the shot yaw at the given distance", function()
    local t = Trajectory.target(point(100, 200, 50), 90, 1000)
    near(t.X, 100, "x")
    near(t.Y, 1200, "y")
    near(t.Z, 50, "z")
end)

test("an undamped flight on flat ground lands on the target", function()
    local start, target = point(0, 0, 0), point(4000, 0, 0)
    local v = Trajectory.launchVelocity(start, target, 0.5, -980)
    local ground = function(from, to)
        if to.Z > 0 then return nil end
        local f = from.Z / (from.Z - to.Z)
        return { location = point(from.X + (to.X - from.X) * f, from.Y + (to.Y - from.Y) * f, 0), normal = point(0, 0, 1) }
    end
    local flight = Trajectory.fly(start, v, { gravityZ = -980, damping = 0, step = 1 / 30, maxTime = 20, hitTest = ground })
    assert(flight.landing ~= nil, "no landing")
    near(flight.landing.location.X, 4000, "landing x", 1)
end)

test("damping shortens the flight slightly", function()
    local v = { X = 2000, Y = 0, Z = 1000 }
    local plain = Trajectory.positionAt(point(0, 0, 0), v, -980, 0, 2)
    local damped = Trajectory.positionAt(point(0, 0, 0), v, -980, 0.01, 2)
    assert(damped.X < plain.X and damped.X > plain.X * 0.98, "damped x " .. damped.X)
end)

local lines = { string.format("%d passed, %d failed", passed, #failures) }
for _, failure in ipairs(failures) do lines[#lines + 1] = "  FAIL " .. failure end
return table.concat(lines, "\n")
