-- GTNH OC System Tools — Setup Script
-- Run this once on your OC computer to download all project files.
-- Requires an Internet Card installed in the computer.
--
-- Usage:
--   wget https://raw.githubusercontent.com/pekkaihalainen1/gtnh-oc-system-tools/refs/heads/main/setup.lua
--   lua setup.lua

local BASE_URL = "https://raw.githubusercontent.com/pekkaihalainen1/gtnh-oc-system-tools/refs/heads/main/"

local FILES = {
    "main.lua",
    "lib/config.lua",
    "lib/ui.lua",
    "modules/power_control.lua",
}

-- ── Dependencies ─────────────────────────────────────────────────────────────

local component  = require("component")
local filesystem = require("filesystem")
local io         = require("io")

if not component.isAvailable("internet") then
    io.write("ERROR: No Internet Card found. Install one and try again.\n")
    os.exit(1)
end

local internet = component.internet

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Download url and return body as string, or nil + error message
local function fetch(url)
    local ok, handle = pcall(internet.request, url)
    if not ok then
        return nil, "request failed: " .. tostring(handle)
    end

    -- Wait for response (handle.response() blocks until headers arrive)
    local status, reason
    local attempts = 0
    repeat
        attempts = attempts + 1
        status, reason = handle.response()
        if not status and attempts > 100 then
            handle.close()
            return nil, "timeout waiting for response"
        end
    until status

    if status ~= 200 then
        handle.close()
        return nil, "HTTP " .. status .. " " .. tostring(reason)
    end

    local body = {}
    while true do
        local chunk = handle.read(8192)
        if chunk == nil then break end
        body[#body + 1] = chunk
    end
    handle.close()

    return table.concat(body)
end

-- Ensure all parent directories for a path exist
local function mkdirs(path)
    local dir = filesystem.path(path)
    if dir and dir ~= "" and not filesystem.isDirectory(dir) then
        local ok, err = filesystem.makeDirectory(dir)
        if not ok then
            return false, err or "could not create " .. dir
        end
    end
    return true
end

-- Write string content to path, creating parents as needed
local function writeFile(path, content)
    local ok, err = mkdirs(path)
    if not ok then return false, err end

    local f, ferr = io.open(path, "w")
    if not f then return false, ferr end
    f:write(content)
    f:close()
    return true
end

-- ── Install root = directory containing setup.lua ────────────────────────────

local function scriptDir()
    -- os.getenv("_") holds the running script path on OC OpenOS
    local script = os.getenv("_") or ""
    local dir = filesystem.path(script)
    return (dir and dir ~= "") and dir or filesystem.workPath()
end

local installRoot = scriptDir()

-- Normalise: ensure trailing slash
if installRoot:sub(-1) ~= "/" then
    installRoot = installRoot .. "/"
end

-- ── Main ─────────────────────────────────────────────────────────────────────

io.write("=== GTNH OC System Tools Setup ===\n")
io.write("Install root: " .. installRoot .. "\n\n")

local ok_count = 0
local fail_count = 0

for _, relPath in ipairs(FILES) do
    local url      = BASE_URL .. relPath
    local destPath = installRoot .. relPath

    io.write(string.format("  Downloading %-35s ... ", relPath))

    local body, err = fetch(url)
    if not body then
        io.write("FAILED (" .. err .. ")\n")
        fail_count = fail_count + 1
    else
        local written, werr = writeFile(destPath, body)
        if not written then
            io.write("FAILED (write: " .. tostring(werr) .. ")\n")
            fail_count = fail_count + 1
        else
            io.write("OK\n")
            ok_count = ok_count + 1
        end
    end
end

io.write(string.format("\nDone: %d/%d files installed.\n", ok_count, ok_count + fail_count))

if fail_count == 0 then
    io.write("Run  lua " .. installRoot .. "main.lua  to start.\n")
else
    io.write("Some files failed — check your internet card and try again.\n")
end
