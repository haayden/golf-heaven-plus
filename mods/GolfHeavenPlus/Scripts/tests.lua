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

local lines = { string.format("%d passed, %d failed", passed, #failures) }
for _, failure in ipairs(failures) do lines[#lines + 1] = "  FAIL " .. failure end
return table.concat(lines, "\n")
