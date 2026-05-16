-- Power control module for Lapotronic Supercapacitor
-- Redstone ON when energy > highThreshold, OFF when energy < lowThreshold
local component = require("component")
local thread    = require("thread")
local os        = require("os")
local ui        = require("lib/ui")

local M = {}
M.id   = "power_control"
M.name = "Power Control"

-- Injected by main before init(); overwritten with file-loaded values
M.config = {
    checkInterval  = 5,
    lowThreshold   = 0.20,
    highThreshold  = 0.90,
    redstoneSide   = 1,
}

-- Internal state — written by background thread, read by drawUI
local state = {
    energyPercent  = 0,
    redstoneActive = false,
    lastUpdate     = "--:--:--",
    error          = nil,
}

local _gpu        = nil
local _redstoneIO = nil
local _detector   = nil
local _thread     = nil

-- ── Component helpers ────────────────────────────────────────────────────────

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

local function readEnergy(det)
    -- GT machine adapter (Lapotronic Supercapacitor via OC Adapter block)
    if det.getEUStored and det.getEUCapacity then
        local cur = det.getEUStored()
        local max = det.getEUCapacity()
        if max == 0 then return 0 end
        return cur / max
    elseif det.getEnergyStored and det.getMaxEnergyStored then
        local cur = det.getEnergyStored()
        local max = det.getMaxEnergyStored()
        if max == 0 then return 0 end
        return cur / max
    elseif det.getStored and det.getCapacity then
        local cur = det.getStored()
        local max = det.getCapacity()
        if max == 0 then return 0 end
        return cur / max
    end
    error("Unknown energy detector API")
end

local function setRedstone(active)
    if not _redstoneIO then return end
    _redstoneIO.setOutput(M.config.redstoneSide, active and 15 or 0)
    state.redstoneActive = active
end

-- ── Module API ───────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    _gpu = gpu

    if not component.isAvailable("redstone") then
        return false, "No redstone I/O block found"
    end
    _redstoneIO = component.redstone

    _detector = findDetector()
    if not _detector then
        return false, "No energy detector found (gt_machine, gt_energydetector, or energy_device)"
    end

    -- Start with redstone off
    setRedstone(false)
    return true
end

function M.start()
    local cfg = M.config  -- capture reference

    _thread = thread.create(function()
        while true do
            local ok, result = pcall(function()
                local pct = readEnergy(_detector)
                state.energyPercent = pct
                state.lastUpdate    = os.date("%H:%M:%S")
                state.error         = nil

                -- Hysteresis: ON above highThreshold, OFF below lowThreshold
                if not state.redstoneActive and pct >= cfg.highThreshold then
                    setRedstone(true)
                elseif state.redstoneActive and pct <= cfg.lowThreshold then
                    setRedstone(false)
                end
            end)

            if not ok then
                state.error = tostring(result)
            end

            os.sleep(cfg.checkInterval)
        end
    end)

    return _thread
end

function M.stop()
    if _thread then
        _thread:kill()
        _thread = nil
    end
    pcall(setRedstone, false)
end

function M.getStatus()
    return {
        energyPercent  = state.energyPercent,
        redstoneActive = state.redstoneActive,
        lastUpdate     = state.lastUpdate,
        error          = state.error,
    }
end

function M.drawUI(gpu, x, y, w, h)
    local cfg = M.config
    ui.clearRegion(gpu, x, y, w, h)

    -- Title row
    gpu.setForeground(0x00FFFF)
    ui.setCentered(gpu, x, y + 1, w, "LAPATRONIC SUPERCAPACITOR CONTROLLER")

    -- Last update timestamp (right-aligned)
    gpu.setForeground(0x888888)
    local ts = "Updated: " .. state.lastUpdate
    gpu.set(x + w - #ts, y + 1, ts)

    -- Energy label
    gpu.setForeground(0xFFFF00)
    gpu.set(x + 2, y + 3, "ENERGY LEVEL:")

    -- Progress bar
    local barX = x + 2
    local barY = y + 4
    local barW = w - 4
    local barH = 3
    local pct  = state.energyPercent
    local color = ui.getEnergyColor(pct, cfg.lowThreshold, cfg.highThreshold)
    ui.drawProgressBar(gpu, barX, barY, barW, barH, pct, color)

    -- Percentage centered inside bar
    gpu.setForeground(0xFFFFFF)
    ui.setCentered(gpu, barX, barY + 1, barW, string.format("%.1f%%", pct * 100))

    -- Threshold markers below bar
    gpu.setForeground(0xFF4444)
    local lowCol = barX + math.floor((barW - 2) * cfg.lowThreshold)
    gpu.set(lowCol, barY + barH + 1, string.format("%.0f%%↑", cfg.lowThreshold * 100))

    gpu.setForeground(0x44FF44)
    local highCol = barX + math.floor((barW - 2) * cfg.highThreshold) - 3
    gpu.set(highCol, barY + barH + 1, string.format("%.0f%%↑", cfg.highThreshold * 100))

    -- Redstone status badge
    gpu.setForeground(0xFFFF00)
    gpu.set(x + 2, barY + barH + 3, "REDSTONE SIGNAL:")
    local badgeColor = state.redstoneActive and 0xCC0000 or 0x555555
    local badgeText  = state.redstoneActive and "  ACTIVE  " or " INACTIVE "
    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(badgeColor)
    gpu.set(x + 20, barY + barH + 3, badgeText)
    gpu.setBackground(0x000000)

    -- Config info
    gpu.setForeground(0x666666)
    gpu.set(x + 2, barY + barH + 5, string.format(
        "Control: ON >%.0f%%  OFF <%.0f%%   Interval: %ds   Side: %d   [Q] Quit  [Tab] Switch",
        cfg.highThreshold * 100, cfg.lowThreshold * 100,
        cfg.checkInterval, cfg.redstoneSide
    ))

    -- Error line
    if state.error then
        gpu.setForeground(0xFF4444)
        gpu.set(x + 2, y + h - 1, "ERR: " .. state.error:sub(1, w - 8))
    end

    gpu.setForeground(0xFFFFFF)
end

-- No special key handling for now
function M.handleKey(char, code) end

return M
