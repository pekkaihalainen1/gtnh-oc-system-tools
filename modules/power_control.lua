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
    euNet          = 0,   -- EU/t net (positive = charging, negative = draining)
    redstoneActive = false,
    lastUpdate     = "--:--:--",
    error          = nil,
}

local _redstoneIO  = nil
local _detector    = nil
local _lastCheck   = 0
local _prevStored  = nil   -- for delta-based net flow
local _prevTime    = nil

-- ── Colors ────────────────────────────────────────────────────────────────────

local C_TITLE  = 0xFF00FF
local C_LABEL  = 0x00CCCC
local C_VALUE  = 0xFFFFFF
local C_DIM    = 0x1155CC
local C_PANEL  = 0x111122
local C_POS    = 0x00FF88
local C_NEG    = 0xFF4444
local C_SEP    = 0x1155CC

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

        state.euStored   = stored or 0
        state.euCapacity = cap    or 0
        state.energyPercent = (cap and cap > 0) and (stored / cap) or 0
        state.lastUpdate = os.date("%H:%M:%S")
        state.error      = nil

        -- Net flow: delta EU between checks, converted to EU/t (20t/s)
        if _prevStored ~= nil and _prevTime ~= nil then
            local dt = now - _prevTime
            if dt > 0 then
                state.euNet = ((stored - _prevStored) / dt) / 20
            end
        end
        _prevStored = stored
        _prevTime   = now

        -- Hysteresis control
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
    local cfg    = M.config
    local pct    = state.energyPercent
    local color  = ui.getEnergyColor(pct, cfg.lowThreshold, cfg.highThreshold)

    -- Time estimates from net flow
    local netPerSec   = state.euNet * 20
    local timeToFull  = (netPerSec >  1) and (state.euCapacity - state.euStored) / netPerSec  or nil
    local timeToEmpty = (netPerSec < -1) and  state.euStored                     / (-netPerSec) or nil

    -- Clear
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx = x + 2   -- content left margin
    local row = y      -- current row cursor

    -- ── Title ────────────────────────────────────────────────────────────────
    row = row + 1
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "LAPOTRONIC SUPERCAPACITOR")
    gpu.setForeground(C_DIM)
    gpu.set(x + w - 1 - #state.lastUpdate, row, state.lastUpdate)
    -- thin separator after title
    gpu.setForeground(C_SEP)
    local sepStart = cx + 26
    local sepEnd   = x + w - 2 - #state.lastUpdate - 1
    if sepEnd > sepStart then
        gpu.fill(sepStart, row, sepEnd - sepStart, 1, "─")
    end

    -- ── Energy bar (5 rows thick, 10-char margin each side) ──────────────────
    local MARGIN  = 10
    row = row + 2
    local barX    = x + MARGIN
    local barW    = w - MARGIN * 2
    local barH    = 5
    local filled  = math.floor(barW * math.max(0, math.min(1, pct)))
    local midRow  = row + math.floor(barH / 2)

    for r = row, row + barH - 1 do
        if filled > 0 then
            gpu.setBackground(color)
            gpu.fill(barX, r, filled, 1, " ")
        end
        if filled < barW then
            gpu.setBackground(C_PANEL)
            gpu.fill(barX + filled, r, barW - filled, 1, " ")
        end
    end
    -- Percentage centered in middle row of bar
    gpu.setBackground(color)
    gpu.setForeground(0x000000)
    local pctStr = string.format("%.1f%%", pct * 100)
    local pctX   = barX + math.floor((barW - #pctStr) / 2)
    gpu.set(pctX, midRow, pctStr)
    gpu.setBackground(0x000000)

    -- Threshold tick marks below bar
    row = row + barH
    gpu.setForeground(C_NEG)
    local lowX = barX + math.floor(barW * cfg.lowThreshold)
    gpu.set(lowX, row, string.format("%.0f%%", cfg.lowThreshold * 100))
    gpu.setForeground(C_POS)
    local highX = barX + math.floor(barW * cfg.highThreshold) - 3
    gpu.set(highX, row, string.format("%.0f%%", cfg.highThreshold * 100))

    -- ── Data rows ─────────────────────────────────────────────────────────────
    row = row + 2

    local function label(r, lbl, val, vc)
        gpu.setForeground(C_LABEL)
        gpu.setBackground(0x000000)
        gpu.set(cx, r, lbl)
        gpu.setForeground(vc or C_VALUE)
        gpu.set(cx + 11, r, val)
    end

    label(row, "STORED    ",
        ui.formatEU(state.euStored) .. "  /  " .. ui.formatEU(state.euCapacity))
    row = row + 2

    local netColor = state.euNet >= 0 and C_POS or C_NEG
    label(row, "NET FLOW  ", string.format("%+.0f EU/t", state.euNet), netColor)
    row = row + 1

    local col2 = cx + 30
    label(row, "FULL IN   ", ui.formatTime(timeToFull))
    gpu.setForeground(C_LABEL)
    gpu.set(col2, row, "EMPTY IN  ")
    gpu.setForeground(C_VALUE)
    gpu.set(col2 + 10, row, ui.formatTime(timeToEmpty))

    -- ── Separator ─────────────────────────────────────────────────────────────
    row = row + 2
    gpu.setForeground(C_SEP)
    gpu.fill(cx, row, w - 4, 1, "─")

    -- ── Redstone section ──────────────────────────────────────────────────────
    row = row + 1
    gpu.setForeground(C_LABEL)
    gpu.set(cx, row, "REDSTONE  ")
    local badgeBg  = state.redstoneActive and 0xAA0000 or 0x222233
    local badgeTxt = state.redstoneActive and " ACTIVE " or "INACTIVE"
    gpu.setForeground(C_VALUE)
    gpu.setBackground(badgeBg)
    gpu.set(cx + 10, row, " " .. badgeTxt .. " ")
    gpu.setBackground(0x000000)
    gpu.setForeground(C_DIM)
    gpu.set(cx + 22, row, string.format(
        "ON >%.0f%%  ·  OFF <%.0f%%  ·  Side: %d",
        cfg.highThreshold * 100, cfg.lowThreshold * 100, cfg.redstoneSide))

    -- ── Footer hint ───────────────────────────────────────────────────────────
    gpu.setForeground(C_DIM)
    gpu.set(cx, y + h - 1,
        string.format("Interval: %ds     [Q] Quit     [Tab] Switch", cfg.checkInterval))

    -- ── Error overlay ─────────────────────────────────────────────────────────
    if state.error then
        gpu.setForeground(C_NEG)
        gpu.set(cx, y + h - 2, ("ERR: " .. state.error):sub(1, w - 4))
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

function M.handleKey(char, code) end

return M
