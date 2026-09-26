-- Per-frame loops that stop themselves when the mod is asked to quit. Restarting a mod while UE4SS
-- is running one of its loops crashes the game inside UE4SS, so the dev harness sets the quit flag,
-- waits for every loop to cancel itself, and only then restarts the mod.
local Loop = {}

Loop.QUIT = "GolfHeavenPlus.Quit" -- shared variable (visible to every mod) that asks this one to stop

function Loop.quitting()
    return ModRef:GetSharedVariable(Loop.QUIT) == true
end

-- Runs fn every `frames` frames until the mod is asked to quit. Errors are logged once each
-- rather than raised, so one bad frame can't stop the loop.
function Loop.every(frames, name, fn)
    local handle, lastError = nil, nil
    handle = LoopInGameThreadAfterFrames(frames, function()
        if Loop.quitting() then
            CancelDelayedAction(handle)
            return
        end
        local ok, err = pcall(fn)
        local message = not ok and tostring(err) or nil
        if message and message ~= lastError then print("[GolfHeavenPlus] " .. name .. ": " .. message .. "\n") end
        lastError = message
    end)
    return handle
end

-- A freshly loaded copy of the mod runs until told otherwise.
function Loop.reset()
    ModRef:SetSharedVariable(Loop.QUIT, false)
end

return Loop
