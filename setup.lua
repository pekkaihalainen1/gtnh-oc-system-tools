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

local component     = require("component")
local filesystem    = require("filesystem")
local computer      = require("computer")
local event         = require("event")
local serialization = require("serialization")
local io            = require("io")

if not component.isAvailable("internet") then
    io.write("ERROR: No Internet Card found. Install one and try again.\n")
    os.exit(1)
end

local internet = component.internet

-- ── File download helpers ─────────────────────────────────────────────────────

local function fetch(url)
    local ok, handle = pcall(internet.request, url)
    if not ok then
        return nil, "request failed: " .. tostring(handle)
    end

    local deadline = computer.uptime() + 15
    local status, reason
    repeat
        status, reason = handle.response()
        if not status then
            os.sleep(0.25)
        end
    until status or computer.uptime() > deadline

    if not status then
        handle.close()
        return nil, "timeout waiting for response"
    end

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

local function writeFile(path, content)
    local ok, err = mkdirs(path)
    if not ok then return false, err end
    local f, ferr = io.open(path, "w")
    if not f then return false, ferr end
    f:write(content)
    f:close()
    return true
end

-- ── Install root ──────────────────────────────────────────────────────────────

local function scriptDir()
    local script = os.getenv("_") or ""
    local dir = filesystem.path(script)
    return (dir and dir ~= "") and dir or filesystem.workPath()
end

local installRoot = scriptDir()
if installRoot:sub(-1) ~= "/" then
    installRoot = installRoot .. "/"
end

-- ── GPU selection UI ──────────────────────────────────────────────────────────

local function pickGPU(gpu, screenW, screenH)
    -- Collect all GPUs with their capabilities
    local gpus = {}
    for addr in component.list("gpu") do
        local maxW, maxH = component.invoke(addr, "maxResolution")
        local depth      = component.invoke(addr, "maxDepth")
        local tier = depth == 8 and "T3" or depth == 4 and "T2" or "T1"
        table.insert(gpus, {
            address   = addr,
            shortAddr = addr:sub(1, 13) .. "...",
            maxW      = maxW,
            maxH      = maxH,
            tier      = tier,
        })
    end

    if #gpus == 0 then
        io.write("No GPU found — skipping GPU selection.\n")
        return nil
    end

    if #gpus == 1 then
        io.write("Single GPU found, selecting it automatically.\n")
        return gpus[1].address
    end

    -- Draw selection screen
    local BOX_H    = 3
    local BOX_X    = 4
    local BOX_W    = screenW - 6
    local START_Y  = 5

    gpu.setBackground(0x000000)
    gpu.fill(1, 1, screenW, screenH, " ")

    gpu.setForeground(0x00FFFF)
    gpu.set(3, 2, "Select GPU for GTNH OC System Tools")
    gpu.setForeground(0x666666)
    gpu.set(3, 3, "Click a box to choose. Timeout in 60s = first GPU.")

    local boxes = {}
    for i, g in ipairs(gpus) do
        local y = START_Y + (i - 1) * (BOX_H + 1)
        boxes[i] = { y = y, h = BOX_H }

        gpu.setBackground(0x1a1a2e)
        gpu.setForeground(0xFFFFFF)
        gpu.fill(BOX_X, y, BOX_W, BOX_H, " ")

        gpu.setForeground(0xFFFF00)
        gpu.set(BOX_X + 2, y + 1,
            string.format("[%d]  %s  %s  %dx%d max",
                i, g.tier, g.shortAddr, g.maxW, g.maxH))
    end
    gpu.setBackground(0x000000)

    -- Wait for a mouse click
    local selected = nil
    local deadline = computer.uptime() + 60
    while computer.uptime() < deadline do
        local remaining = deadline - computer.uptime()
        local ev, _, x, y = event.pull(math.min(remaining, 1), "touch")
        if ev == "touch" then
            for i, box in ipairs(boxes) do
                if y >= box.y and y < box.y + box.h
                        and x >= BOX_X and x <= BOX_X + BOX_W then
                    selected = gpus[i]
                    break
                end
            end
            if selected then break end
        end
    end

    gpu.fill(1, 1, screenW, screenH, " ")

    if selected then
        io.write("Selected GPU: " .. selected.address .. "\n")
        return selected.address
    else
        io.write("Timeout — using first GPU.\n")
        return gpus[1].address
    end
end

-- ── Config helpers ────────────────────────────────────────────────────────────

local function loadConfig(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(serialization.unserialize, raw)
    return (ok and type(data) == "table") and data or {}
end

local function saveConfig(path, data)
    local f = io.open(path, "w")
    if not f then return end
    f:write(serialization.serialize(data))
    f:close()
end

-- ── Main ──────────────────────────────────────────────────────────────────────

io.write("=== GTNH OC System Tools Setup ===\n")
io.write("Install root: " .. installRoot .. "\n\n")

-- Clean existing managed files (not config)
io.write("Cleaning existing files...\n")
for _, relPath in ipairs(FILES) do
    local destPath = installRoot .. relPath
    if filesystem.exists(destPath) then
        filesystem.remove(destPath)
        io.write("  Removed " .. relPath .. "\n")
    end
end
io.write("\n")

-- Download files
local ok_count   = 0
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

io.write(string.format("\nDone: %d/%d files installed.\n\n", ok_count, ok_count + fail_count))

-- GPU selection (only when all files downloaded OK)
if fail_count == 0 then
    local gpu      = component.gpu
    local screenW, screenH = gpu.getResolution()
    local gpuAddr  = pickGPU(gpu, screenW, screenH)

    if gpuAddr then
        local configPath = installRoot .. "config.cfg"
        local cfg = loadConfig(configPath)
        cfg.gpu = gpuAddr
        saveConfig(configPath, cfg)
        io.write("GPU address saved to config.cfg\n\n")
    end

    io.write("Run  lua " .. installRoot .. "main.lua  to start.\n")
else
    io.write("Some files failed — check your internet card and try again.\n")
end
