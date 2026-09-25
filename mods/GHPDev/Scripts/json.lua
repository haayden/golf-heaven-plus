-- Minimal JSON encoder for the dev recorders: numbers, booleans, nil, strings, arrays and objects.
local Json = {}

local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

-- Only tables whose keys are exactly 1..n are arrays; anything else is written as an object.
local function isArray(t)
    local count = 0
    for key in pairs(t) do
        if math.type(key) ~= "integer" then return false end
        count = count + 1
    end
    return count == #t
end

function Json.encode(value)
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.7g", value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "nil" then
        return "null"
    elseif kind == "table" then
        if isArray(value) then
            local parts = {}
            for i, item in ipairs(value) do parts[i] = Json.encode(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, key in ipairs(keys) do parts[#parts + 1] = jsonString(tostring(key)) .. ":" .. Json.encode(value[key]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return jsonString(tostring(value))
end

return Json
