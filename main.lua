-- GTNH OC System Tools — main shell
-- Manages modules, tab UI, and event loop.
-- Each module runs its control logic in a background thread.

local component = require("component")
local event     = require("event")
local keyboard  = require("keyboard")
local unicode   = require("unicode")
local config    = require("lib/config")
local ui        = require("lib/ui")

-- ── Module registry (add new modules here) ───────────────────────────────────
local MODULES = {
    require("modules/power_control"),
}

-- ── Config ───────────────────────────────────────────────────────────────────
local CONFIG_PATH    = "config.cfg"
local REDRAW_INTERVAL = 1  -- seconds between forced redraws

-- ── Globals ──────────────────────────────────────────────────────────────────
local gpu         = nil
local screenW     = 0
local screenH     = 0
local activeIdx   = 1
local threads     = {}
local cfg         = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function fatal(msg)
    if gpu then
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFF4444)
        gpu.set(1, 1, "FATAL: " .. tostring(msg))
    else
        io.write("FATAL: " .. tostring(msg) .. "\n")
    end
    os.exit(1)
end

local function initGPU()
    if not component.isAvailable("gpu") then
        fatal("No GPU found. Install a graphics card.")
    end
    gpu = component.gpu

    if not component.isAvailable("screen") then
        fatal("No screen found. Connect a screen.")
    end
    gpu.bind(component.screen.address)
    screenW, screenH = gpu.getResolution()
end

-- ── Layout constants (computed after screen init) ────────────────────────────
-- Tab bar occupies row 1; module UI gets rows 2..screenH
local function moduleArea()
    return 1, 2, screenW, screenH - 1
end

-- ── Drawing ──────────────────────────────────────────────────────────────────

local function redraw()
    ui.drawTabBar(gpu, screenW, MODULES, activeIdx)
    local x, y, w, h = moduleArea()
    MODULES[activeIdx].drawUI(gpu, x, y, w, h)
end

-- ── Shutdown ─────────────────────────────────────────────────────────────────

local function shutdown()
    -- Stop modules in reverse order (undo dependencies)
    for i = #MODULES, 1, -1 do
        pcall(MODULES[i].stop)
    end

    -- Clear screen and show goodbye
    gpu.setBackground(0x000000)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 1, screenW, screenH, " ")
    ui.setCentered(gpu, 1, math.floor(screenH / 2), screenW, "GTNH Tools stopped.")
    os.sleep(1)
    gpu.fill(1, 1, screenW, screenH, " ")
end

-- ── Main ─────────────────────────────────────────────────────────────────────

local function main()
    -- GPU first so fatal() can write to screen
    initGPU()

    -- Build defaults table: { [module.id] = module.config }
    local defaults = {}
    for _, mod in ipairs(MODULES) do
        defaults[mod.id] = mod.config
    end

    -- Load config, injecting saved values back into each module
    cfg = config.load(CONFIG_PATH, defaults)
    for _, mod in ipairs(MODULES) do
        if cfg[mod.id] then
            mod.config = cfg[mod.id]
        end
    end

    -- Initialize each module
    for _, mod in ipairs(MODULES) do
        local ok, err = mod.init(gpu, screenW, screenH)
        if not ok then
            fatal("Module '" .. mod.name .. "' init failed: " .. tostring(err))
        end
    end

    -- Start background threads
    for _, mod in ipairs(MODULES) do
        local t = mod.start()
        table.insert(threads, t)
    end

    -- Initial draw
    redraw()

    -- Event loop
    while true do
        local ev, _, _, code = event.pull(REDRAW_INTERVAL,
                                          "key_down", "interrupted")

        if ev == "interrupted" then
            break
        elseif ev == "key_down" then
            if code == keyboard.keys.tab then
                -- Cycle to next module
                activeIdx = (activeIdx % #MODULES) + 1
                redraw()
            else
                -- Delegate to active module
                local char = unicode.char(code)
                MODULES[activeIdx].handleKey(char, code)
                redraw()
            end
        else
            -- Timeout — just redraw to refresh live data
            redraw()
        end
    end

    shutdown()
end

-- Top-level error guard
local ok, err = pcall(main)
if not ok then
    if gpu then
        gpu.setBackground(0x000000)
        gpu.setForeground(0xFF4444)
        gpu.fill(1, 1, screenW, screenH, " ")
        gpu.set(1, 1, "Unhandled error: " .. tostring(err))
        gpu.set(1, 2, "Check component connections and restart.")
    else
        io.write("Unhandled error: " .. tostring(err) .. "\n")
    end
    -- Best-effort cleanup
    for _, mod in ipairs(MODULES) do
        pcall(mod.stop)
    end
end
