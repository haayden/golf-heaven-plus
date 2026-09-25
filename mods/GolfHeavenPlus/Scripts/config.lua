-- Settings for Golf Heaven Plus, stored as `key=value` lines in config.txt next to the mod.
local Config = {}

Config.DEFAULTS = {
    trajectory = true,
    tracer = true,
    aim = true,
}

local BOOLEANS = {
    ["true"] = true, on = true, yes = true, ["1"] = true,
    ["false"] = false, off = false, no = false, ["0"] = false,
}

function Config.parse(text)
    local values = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key then
            local boolean = BOOLEANS[value:lower()]
            if boolean == nil then values[key] = value else values[key] = boolean end
        end
    end
    return values
end

function Config.serialize(values)
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. tostring(values[key]) end
    return table.concat(lines, "\n") .. "\n"
end

function Config.load(path)
    local values = {}
    for key, value in pairs(Config.DEFAULTS) do values[key] = value end
    local file = io.open(path, "r")
    if file then
        for key, value in pairs(Config.parse(file:read("a"))) do values[key] = value end
        file:close()
    end
    return values
end

function Config.save(path, values)
    local file, err = io.open(path, "w")
    if not file then return false, err end
    file:write(Config.serialize(values))
    file:close()
    return true
end

return Config
