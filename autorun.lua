-- Automatically starts GTNH OC System Tools on boot.
-- Placed in the same directory as main.lua by setup.lua.
local filesystem = require("filesystem")
local shell      = require("shell")

os.sleep(1)  -- let components finish initializing

local scriptPath = os.getenv("_") or ""
local dir        = filesystem.path(scriptPath)
if not dir or dir == "" then
    dir = shell.getWorkingDirectory()
end
if dir:sub(-1) ~= "/" then dir = dir .. "/" end

local main = dir .. "main.lua"
if filesystem.exists(main) then
    shell.execute(main)
else
    io.write("[autorun] main.lua not found at " .. main .. "\n")
end
