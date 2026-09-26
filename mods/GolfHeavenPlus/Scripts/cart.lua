-- Fast golf cart. The game's cart tops out around 40 km/h: one 4.70 gear, a 4500 RPM limiter and
-- 250 Nm on 35 cm wheels. The rev limit is fixed once the cart exists, so this doubles the
-- engine's torque and, while the driver holds the throttle with wheels on the ground, pushes the
-- cart on towards a higher top speed. The driver's own copy of the game simulates the cart, so it
-- works for whoever drives with the mod.
local Golf = require("golf")
local Loop = require("loop")

local Cart = {}

local CART_CLASS = "/Game/Ride/GolfCart/BP_GolfCart.BP_GolfCart_C"
local MOVEMENT = "Chaos Wheeled Vehicle Movement Component"
local TORQUE = 500        -- Nm, stock 250
local TOP_SPEED = 2200    -- cm/s (about 80 km/h), stock about 41 km/h
local PUSH = 450          -- cm/s² of extra acceleration from a standstill, fading to nothing at TOP_SPEED
local MIN_WHEELS_DOWN = 2 -- wheels touching the ground before pushing, so a jump never becomes a flight

-- Extra acceleration (cm/s²) for a cart going forward at `speed` cm/s with `throttle` (0-1).
function Cart.push(speed, throttle, topSpeed, push)
    if throttle <= 0 or speed < 0 or speed >= topSpeed then return 0 end
    return push * throttle * (1 - speed / topSpeed)
end

-- Runtime -----------------------------------------------------------------------------------------
local enabled = function() return true end
local carts = {} -- golf carts, collected as the game creates them
local tuned = {} -- cart address -> true once its torque is raised
local NONE = nil

local function valid(object) return object ~= nil and object:IsValid() end

local function remember(cart)
    if valid(cart) and not cart:GetFName():ToString():find("^Default__") then carts[#carts + 1] = cart end
end

local function drivenBy(cart, controller)
    local mine = controller:GetAddress()
    local ok, driver = pcall(function() return cart:GetController() end)
    if ok and valid(driver) and driver:GetAddress() == mine then return true end
    local okOverride, override = pcall(function() return cart:GetOverrideController() end)
    return okOverride and valid(override) and override:GetAddress() == mine
end

local function wheelsDown(movement)
    local down = 0
    for i = 0, 3 do
        local ok, state = pcall(function() return movement:GetWheelState(i) end)
        if ok and state and state.bInContact then down = down + 1 end
    end
    return down
end

local function drive(cart)
    local movement = cart[MOVEMENT]
    if not valid(movement) then return end
    local key = cart:GetAddress()
    if not tuned[key] then
        movement:SetMaxEngineTorque(TORQUE)
        tuned[key] = true
    end
    local extra = Cart.push(movement:GetForwardSpeed(), movement:GetThrottleInput(), TOP_SPEED, PUSH)
    if extra <= 0 or wheelsDown(movement) < MIN_WHEELS_DOWN then return end
    local f = cart:GetActorForwardVector()
    cart.Mesh:AddForce({ X = f.X * extra, Y = f.Y * extra, Z = f.Z * extra }, NONE, true)
end

function Cart.update()
    if not enabled() then return end
    local controller = Golf.localController()
    if not valid(controller) then return end
    for i = #carts, 1, -1 do
        local cart = carts[i]
        if not valid(cart) then
            table.remove(carts, i)
        elseif drivenBy(cart, controller) then
            drive(cart)
        end
    end
end

-- isEnabled: function returning whether the fast cart setting is on. Carts are collected as the
-- game spawns them: searching every object is too slow to repeat.
function Cart.start(isEnabled)
    enabled = isEnabled
    NONE = FName("None")
    ExecuteInGameThread(function()
        LoadAsset(CART_CLASS)
        NotifyOnNewObject(CART_CLASS, remember)
        for _, cart in ipairs(FindAllOf("BP_GolfCart_C") or {}) do remember(cart) end
    end)
    Loop.every(1, "cart", Cart.update)
end

return Cart
