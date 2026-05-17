-- Power control module for Lapotronic Supercapacitor
-- Redstone ON when energy > highThreshold, OFF when energy < lowThreshold
-- UI is a small config editor; the dashboard module owns the overview view.
local component = require("component")
local computer  = require("computer")
local os        = require("os")
local keyboard  = require("keyboard")

local M = {}
M.id   = "power_control"
M.name = "Power Control"

M.config = {
    checkInterval  = 5,
    lowThreshold   = 0.20,
    highThreshold  = 0.90,
    redstoneSide   = 1,
}

local state = {
    energyPercent  = 0,
    euStored       = 0,
    euCapacity     = 0,
    euNet          = 0,
    redstoneActive = false,
    lastUpdate     = "--:--:--",
    error          = nil,
}

local _redstoneIO  = nil
local _detector    = nil
local _lastCheck   = 0
local _prevStored  = nil
local _prevTime    = nil

-- ── Colors ────────────────────────────────────────────────────────────────────

local C_TITLE  = 0xFF00FF
local C_LABEL  = 0x00A6FF
local C_VALUE  = 0x00A6FF
local C_DIM    = 0x004477
local C_SEP    = 0x003355
local C_ACT    = 0x002244
local C_NEG    = 0xFF00FF

-- ── Component helpers ─────────────────────────────────────────────────────────

local function findDetector()
    if component.isAvailable("gt_machine") then
        return component.gt_machine
    elseif component.isAvailable("gt_energydetector") then
        return component.gt_energydetector
    elseif component.isAvailable("energy_device") then
        return component.energy_device
    end
    return nil
end

local function setRedstone(active)
    if not _redstoneIO then return end
    _redstoneIO.setOutput(M.config.redstoneSide, active and 15 or 0)
    state.redstoneActive = active
end

-- ── Config editor state ───────────────────────────────────────────────────────

local SIDE_NAMES = { [0]="bottom", [1]="top", [2]="north", [3]="south", [4]="west", [5]="east" }

local editor = {
    mode  = false,
    field = "low",   -- "low" | "high" | "side"
    buf   = "",
    drafts = { low = "20", high = "90", side = "1" },
}

local function saveMyConfig()
    local cfg = require("lib/config")
    local full = cfg.load("config.cfg", {})
    full[M.id] = M.config
    cfg.save("config.cfg", full)
end

local function commitEditorAndSave()
    local d = editor.drafts
    local low  = math.max(0, math.min(100, tonumber(d.low)  or 20))
    local high = math.max(0, math.min(100, tonumber(d.high) or 90))
    local side = math.max(0, math.min(5,   math.floor(tonumber(d.side) or 1)))

    if high <= low then high = math.min(100, low + 5) end

    M.config.lowThreshold  = low  / 100
    M.config.highThreshold = high / 100
    M.config.redstoneSide  = side

    pcall(saveMyConfig)
    -- Apply new side immediately by clearing the old side and re-driving.
    if _redstoneIO then
        pcall(function() _redstoneIO.setOutput(side, state.redstoneActive and 15 or 0) end)
    end
end

local function openEditor()
    editor.mode  = true
    editor.field = "low"
    editor.drafts.low  = tostring(math.floor((M.config.lowThreshold  or 0) * 100 + 0.5))
    editor.drafts.high = tostring(math.floor((M.config.highThreshold or 0) * 100 + 0.5))
    editor.drafts.side = tostring(M.config.redstoneSide or 1)
    editor.buf   = editor.drafts.low
end

local function closeEditor(save)
    if save then
        editor.drafts[editor.field] = editor.buf
        commitEditorAndSave()
    end
    editor.mode = false
    editor.buf  = ""
end

local function advanceField()
    editor.drafts[editor.field] = editor.buf
    if editor.field == "low" then
        editor.field = "high"
        editor.buf   = editor.drafts.high
    elseif editor.field == "high" then
        editor.field = "side"
        editor.buf   = editor.drafts.side
    else
        closeEditor(true)
    end
end

-- ── Module API ────────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    if not component.isAvailable("redstone") then
        return false, "No redstone I/O block found"
    end
    _redstoneIO = component.redstone

    _detector = findDetector()
    if not _detector then
        return false, "No energy detector found (gt_machine, gt_energydetector, or energy_device)"
    end

    setRedstone(false)
    return true
end

function M.start() end

function M.update()
    local now = computer.uptime()
    if now - _lastCheck < M.config.checkInterval then return end
    _lastCheck = now

    local ok, result = pcall(function()
        local det = _detector
        local stored, cap

        if det.getEUStored and det.getEUCapacity then
            stored = det.getEUStored()
            cap    = det.getEUCapacity()
        elseif det.getEnergyStored and det.getMaxEnergyStored then
            stored = det.getEnergyStored()
            cap    = det.getMaxEnergyStored()
        elseif det.getStored and det.getCapacity then
            stored = det.getStored()
            cap    = det.getCapacity()
        else
            error("Unknown energy detector API")
        end

        state.euStored   = stored or 0
        state.euCapacity = cap    or 0
        state.energyPercent = (cap and cap > 0) and (stored / cap) or 0
        state.lastUpdate = os.date("%H:%M:%S")
        state.error      = nil

        if _prevStored ~= nil and _prevTime ~= nil then
            local dt = now - _prevTime
            if dt > 0 then
                state.euNet = ((stored - _prevStored) / dt) / 20
            end
        end
        _prevStored = stored
        _prevTime   = now

        local pct = state.energyPercent
        if not state.redstoneActive and pct >= M.config.highThreshold then
            setRedstone(true)
        elseif state.redstoneActive and pct <= M.config.lowThreshold then
            setRedstone(false)
        end
    end)

    if not ok then
        state.error = tostring(result)
    end
end

function M.stop()
    pcall(setRedstone, false)
end

function M.getStatus()
    return {
        energyPercent  = state.energyPercent,
        euStored       = state.euStored,
        euCapacity     = state.euCapacity,
        euNet          = state.euNet,
        redstoneActive = state.redstoneActive,
        lastUpdate     = state.lastUpdate,
        error          = state.error,
    }
end

-- ── drawUI ────────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx  = x + 2
    local row = y + 1

    -- Title row
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "POWER CONTROL CONFIG")
    gpu.setForeground(C_DIM)
    gpu.set(x + w - 1 - #state.lastUpdate, row, state.lastUpdate)
    gpu.setForeground(C_SEP)
    local sepStart = cx + 22
    local sepEnd   = x + w - 2 - #state.lastUpdate - 1
    if sepEnd > sepStart then
        gpu.fill(sepStart, row, sepEnd - sepStart, 1, "─")
    end

    row = row + 2

    -- Helper: draw one labeled value row.
    local function drawField(r, lbl, value, suffix, isActive)
        gpu.setBackground(0x000000)
        gpu.setForeground(C_LABEL)
        gpu.set(cx, r, lbl)
        local vx = cx + 18
        if isActive then
            gpu.setBackground(C_ACT)
            gpu.setForeground(C_VALUE)
            local txt = string.format(" %s_ ", value)
            gpu.set(vx, r, txt .. string.rep(" ", math.max(0, 8 - #txt)))
        else
            gpu.setBackground(0x000000)
            gpu.setForeground(editor.mode and C_DIM or C_VALUE)
            gpu.set(vx, r, string.format(" %s ", value) .. string.rep(" ", 6))
        end
        gpu.setBackground(0x000000)
        gpu.setForeground(C_DIM)
        if suffix then
            gpu.set(vx + 10, r, suffix)
        end
    end

    local lowVal  = editor.mode and (editor.field == "low"  and editor.buf or editor.drafts.low)
                                 or tostring(math.floor(M.config.lowThreshold  * 100 + 0.5))
    local highVal = editor.mode and (editor.field == "high" and editor.buf or editor.drafts.high)
                                 or tostring(math.floor(M.config.highThreshold * 100 + 0.5))
    local sideVal = editor.mode and (editor.field == "side" and editor.buf or editor.drafts.side)
                                 or tostring(M.config.redstoneSide)

    drawField(row, "LOW THRESHOLD   :", lowVal,
        "%   (redstone OFF below)", editor.mode and editor.field == "low")
    row = row + 2

    drawField(row, "HIGH THRESHOLD  :", highVal,
        "%   (redstone ON above)", editor.mode and editor.field == "high")
    row = row + 2

    local sideNum  = tonumber(sideVal) or -1
    local sideName = SIDE_NAMES[sideNum] or "?"
    drawField(row, "REDSTONE SIDE   :", sideVal,
        string.format("(%s)   0=bot 1=top 2=N 3=S 4=W 5=E", sideName),
        editor.mode and editor.field == "side")
    row = row + 2

    -- Read-only check interval
    gpu.setForeground(C_LABEL)
    gpu.set(cx, row, "CHECK INTERVAL  :")
    gpu.setForeground(C_DIM)
    gpu.set(cx + 18, row, string.format(" %ds  (read-only)", M.config.checkInterval))
    row = row + 3

    -- Hint / footer
    gpu.setForeground(C_SEP)
    gpu.fill(cx, row, w - 4, 1, "─")
    row = row + 1

    gpu.setForeground(C_DIM)
    if editor.mode then
        local fieldLabel = ({low = "LOW THRESHOLD", high = "HIGH THRESHOLD", side = "REDSTONE SIDE"})[editor.field]
        gpu.set(cx, row, string.format("Editing: %s", fieldLabel))
        row = row + 2
        gpu.set(cx, row, "[0-9] Type  [Backspace] Erase  [Enter] Next/Save  [Esc] Cancel")
    else
        gpu.set(cx, row, "Press [Enter] to edit thresholds and redstone side")
        row = row + 2
        gpu.set(cx, row, "Settings persist to config.cfg")
    end

    -- Footer
    gpu.setForeground(C_DIM)
    gpu.set(cx, y + h - 1, "[Q] Quit     [Tab] Switch tab")

    -- Error overlay
    if state.error then
        gpu.setForeground(C_NEG)
        gpu.set(cx, y + h - 2, ("ERR: " .. state.error):sub(1, w - 4))
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

-- ── handleKey ────────────────────────────────────────────────────────────────

function M.handleKey(char, code)
    if not editor.mode then
        if code == keyboard.keys.enter then
            openEditor()
        end
        return
    end

    -- Edit mode
    if char >= 48 and char <= 57 then  -- digits 0-9
        if #editor.buf < 4 then
            editor.buf = editor.buf .. string.char(char)
        end
    elseif code == keyboard.keys.back then
        editor.buf = editor.buf:sub(1, -2)
    elseif code == keyboard.keys.enter then
        advanceField()
    elseif code == keyboard.keys.escape then
        closeEditor(false)
    end
end

return M
