-- Power control module for Lapotronic Supercapacitor
-- Redstone ON when energy > highThreshold, OFF when energy < lowThreshold
local component = require("component")
local computer  = require("computer")
local os        = require("os")
local ui        = require("lib/ui")

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
    euInput        = 0,   -- EU/t average input
    euOutput       = 0,   -- EU/t average output
    redstoneActive = false,
    lastUpdate     = "--:--:--",
    error          = nil,
}

local _redstoneIO = nil
local _detector   = nil
local _lastCheck  = 0

-- ── Colors ───────────────────────────────────────────────────────────────────

local C_BORDER   = 0x00CCCC
local C_TITLE    = 0xFF00FF
local C_LABEL    = 0xFF00FF
local C_VALUE    = 0xFFFFFF
local C_DIM      = 0x555577
local C_PANEL    = 0x0D0D1A
local C_POS      = 0x00FF88
local C_NEG      = 0xFF4444

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

        state.euStored    = stored or 0
        state.euCapacity  = cap    or 0
        state.energyPercent = (cap and cap > 0) and (stored / cap) or 0
        state.lastUpdate  = os.date("%H:%M:%S")
        state.error       = nil

        -- Flow rates (best-effort; silently 0 if not supported)
        local inp = 0
        if det.getAverageElectricInput then
            pcall(function() inp = det.getAverageElectricInput() or 0 end)
        end
        local out = 0
        if det.getAverageElectricOutput then
            pcall(function() out = det.getAverageElectricOutput() or 0 end)
        end
        state.euInput  = inp
        state.euOutput = out

        -- Hysteresis: ON above highThreshold, OFF below lowThreshold
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
        euInput        = state.euInput,
        euOutput       = state.euOutput,
        redstoneActive = state.redstoneActive,
        lastUpdate     = state.lastUpdate,
        error          = state.error,
    }
end

-- ── drawUI ────────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    local cfg   = M.config
    local pct   = state.energyPercent
    local color = ui.getEnergyColor(pct, cfg.lowThreshold, cfg.highThreshold)

    -- Derived flow values
    local net       = state.euInput - state.euOutput     -- EU/t
    local netPerSec = net * 20                            -- EU/s
    local timeToFull, timeToEmpty
    if netPerSec > 0 then
        timeToFull  = (state.euCapacity - state.euStored) / netPerSec
    elseif netPerSec < 0 then
        timeToEmpty = state.euStored / (-netPerSec)
    end

    -- Layout constants
    local BAR_W   = 12   -- left column width including outer border
    local barInX  = x + 1          -- inner bar x start
    local barInW  = BAR_W - 2      -- inner bar width (no borders)
    local hdrH    = 2               -- header rows (title + separator)
    local ftrH    = 2               -- footer rows (separator + hint)
    local barInY  = y + hdrH + 1   -- bar starts after header + top border
    local barInH  = h - hdrH - ftrH - 2  -- bar height (minus borders and footer)
    local rColX   = x + BAR_W + 1  -- right column content start
    local rColW   = w - BAR_W - 2  -- right column content width

    -- ── Clear entire region ──────────────────────────────────────────────────
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    -- ── Outer border (full box) ──────────────────────────────────────────────
    gpu.setForeground(C_BORDER)
    gpu.setBackground(0x000000)
    -- Top edge
    gpu.fill(x,         y,     w, 1, "═")
    gpu.set (x,         y,         "╔")
    gpu.set (x + w - 1, y,         "╗")
    -- Bottom edge
    gpu.fill(x,         y + h - 1, w, 1, "═")
    gpu.set (x,         y + h - 1, "╚")
    gpu.set (x + w - 1, y + h - 1, "╝")
    -- Left edge
    gpu.fill(x,         y + 1, 1, h - 2, "║")
    -- Right edge
    gpu.fill(x + w - 1, y + 1, 1, h - 2, "║")

    -- ── Title row ────────────────────────────────────────────────────────────
    gpu.setForeground(C_TITLE)
    gpu.set(x + 2, y + 1, "LAPOTRONIC SUPERCAPACITOR")
    gpu.setForeground(C_DIM)
    local ts = state.lastUpdate
    gpu.set(x + w - 1 - #ts, y + 1, ts)

    -- ── Header separator: ╠══...══╦══...══╣ ────────────────────────────────
    local sepY = y + hdrH
    gpu.setForeground(C_BORDER)
    gpu.fill(x,             sepY, w, 1, "═")
    gpu.set (x,             sepY, "╠")
    gpu.set (x + w - 1,    sepY, "╣")
    gpu.set (x + BAR_W,    sepY, "╦")

    -- ── Vertical divider (left column right wall) ────────────────────────────
    gpu.fill(x + BAR_W, y + hdrH + 1, 1, h - hdrH - ftrH - 2, "║")

    -- ── Vertical energy bar ──────────────────────────────────────────────────
    if barInH > 0 then
        ui.drawVerticalBar(gpu, barInX, barInY, barInW, barInH, pct, color)
    end

    -- Percentage label below bar
    local pctStr = string.format("%.1f%%", pct * 100)
    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
    ui.setCentered(gpu, barInX, y + h - ftrH - 1, barInW, pctStr)

    -- ── Right column content rows ─────────────────────────────────────────────
    local function rRow(row, label, value, valColor)
        gpu.setForeground(C_LABEL)
        gpu.setBackground(0x000000)
        gpu.set(rColX, row, label)
        gpu.setForeground(valColor or C_VALUE)
        gpu.set(rColX + 10, row, value)
    end

    local r = y + hdrH + 1   -- current right-column row

    -- STORED
    rRow(r, "STORED  ", ui.formatEU(state.euStored))
    r = r + 1
    gpu.setForeground(C_DIM)
    gpu.set(rColX + 10, r,
        "/ " .. ui.formatEU(state.euCapacity) ..
        "  (" .. string.format("%.1f%%", pct * 100) .. ")")
    r = r + 2

    -- FLOW
    local function fmtFlow(euPerTick)
        return string.format("%+.0f EU/t", euPerTick)
    end
    rRow(r, "INPUT   ", fmtFlow(state.euInput),  C_POS) ; r = r + 1
    rRow(r, "OUTPUT  ", fmtFlow(-state.euOutput), C_NEG) ; r = r + 1
    local netColor = net >= 0 and C_POS or C_NEG
    rRow(r, "NET     ", fmtFlow(net), netColor) ; r = r + 2

    -- TIME ESTIMATES
    rRow(r, "FULL IN ", ui.formatTime(timeToFull),  C_VALUE) ; r = r + 1
    rRow(r, "EMPTY IN", ui.formatTime(timeToEmpty), C_VALUE) ; r = r + 1

    -- ── Redstone divider ─────────────────────────────────────────────────────
    local rsDivY = r
    gpu.setForeground(C_BORDER)
    gpu.fill(x + BAR_W,    rsDivY, w - BAR_W - 1, 1, "═")
    gpu.set (x + BAR_W,    rsDivY, "╠")
    gpu.set (x + w - 1,    rsDivY, "╣")
    r = r + 1

    -- REDSTONE STATUS
    gpu.setForeground(C_LABEL)
    gpu.set(rColX, r, "REDSTONE SIGNAL")
    local badgeBg   = state.redstoneActive and 0xAA0000 or 0x222222
    local badgeTxt  = state.redstoneActive and " ACTIVE " or "INACTIVE"
    gpu.setForeground(C_VALUE)
    gpu.setBackground(badgeBg)
    gpu.set(rColX + 17, r, " " .. badgeTxt .. " ")
    gpu.setBackground(0x000000)
    r = r + 1

    gpu.setForeground(C_DIM)
    gpu.set(rColX, r,
        string.format("ON >%.0f%%  ·  OFF <%.0f%%  ·  Side: %d",
            cfg.highThreshold * 100, cfg.lowThreshold * 100, cfg.redstoneSide))
    r = r + 1

    -- ── Footer divider ────────────────────────────────────────────────────────
    local ftrDivY = y + h - ftrH - 1
    if r <= ftrDivY then
        gpu.setForeground(C_BORDER)
        gpu.fill(x + BAR_W,  ftrDivY, w - BAR_W - 1, 1, "═")
        gpu.set (x + BAR_W,  ftrDivY, "╠")
        gpu.set (x + w - 1,  ftrDivY, "╣")
        -- bottom-left corner of vertical divider
        gpu.set (x + BAR_W,  y + h - 1, "╩")
    end

    -- HINT row
    gpu.setForeground(C_DIM)
    gpu.set(rColX, y + h - 1,
        string.format("Interval: %ds     [Q] Quit   [Tab] Switch", cfg.checkInterval))

    -- ── Error overlay ─────────────────────────────────────────────────────────
    if state.error then
        gpu.setForeground(C_NEG)
        gpu.setBackground(0x000000)
        gpu.set(x + 2, y + h - 2, ("ERR: " .. state.error):sub(1, w - 4))
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

function M.handleKey(char, code) end

return M
