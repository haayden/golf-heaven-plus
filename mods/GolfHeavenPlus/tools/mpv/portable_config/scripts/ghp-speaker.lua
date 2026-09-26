-- Golf Heaven Plus speaker helper, run inside mpv (see ../mpv.conf). The game mod talks to it with
-- script messages over mpv's IPC pipe:
--   ghp-play-clipboard  play the link on the Windows clipboard (YouTube links go through yt-dlp)
--   ghp-play <url>      play a given link
--   ghp-stop            stop playing
--   ghp-heartbeat       the game is still running; with none for HEARTBEAT_TIMEOUT s, mpv quits
-- What is happening is written to speaker-status.txt next to this config for the mod to show.
local HEARTBEAT_TIMEOUT = 15

local statusPath = mp.command_native({ "expand-path", "~~/speaker-status.txt" })
local lastBeat = mp.get_time()

local function status(text)
    local file = io.open(statusPath, "w")
    if file then
        file:write(text)
        file:close()
    end
end

local function play(url)
    url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not url:match("^https?://") then
        status("error: copy a YouTube link first")
        return
    end
    status("loading")
    mp.commandv("loadfile", url, "replace")
end

mp.register_script_message("ghp-play-clipboard", function() play(mp.get_property("clipboard/text")) end)
mp.register_script_message("ghp-play", play)
mp.register_script_message("ghp-stop", function()
    mp.commandv("stop")
    status("stopped")
end)
mp.register_script_message("ghp-heartbeat", function() lastBeat = mp.get_time() end)

mp.observe_property("media-title", "string", function(_, title)
    if title and title ~= "" and mp.get_property("path") then status("playing: " .. title) end
end)
mp.register_event("end-file", function(event)
    if event.reason == "error" then status("error: couldn't play that link") end
end)

mp.add_periodic_timer(2, function()
    if mp.get_time() - lastBeat > HEARTBEAT_TIMEOUT then mp.command("quit") end
end)

status("ready")
