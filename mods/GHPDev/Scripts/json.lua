-- Minimal JSON encoder for the dev recorders: numbers, booleans, nil, strings, arrays and objects.
local Json = {}

local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
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
        if value[1] ~= nil or next(value) == nil then
            local parts = {}
            for i, item in ipairs(value) do parts[i] = Json.encode(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do parts[#parts + 1] = jsonString(key) .. ":" .. Json.encode(value[key]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return jsonString(tostring(value))
end

return Json
