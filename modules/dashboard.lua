-- Dashboard module: read-only overview of power state and crafting history.
-- Has no logic of its own; pulls data from power_control and item_stocker
-- via their public accessors.
local unicode  = require("unicode")
local keyboard = require("keyboard")
local ui       = require("lib/ui")

local M = {}
M.id     = "dashboard"
M.name   = "Dashboard"
M.config = {}

-- ── Cross-module lazy references ─────────────────────────────────────────────

local _power   = nil
local _stocker = nil

local function getPower()
    if not _power then
        local ok, m = pcall(require, "modules/power_control")
        if ok and m then _power = m end
    end
    return _power
end

local function getStocker()
    if not _stocker then
        local ok, m = pcall(require, "modules/item_stocker")
        if ok and m then _stocker = m end
    end
    return _stocker
end

-- ── Colors (mirror power_control palette) ────────────────────────────────────

local C_TITLE  = 0xFF00FF
local C_LABEL  = 0x00A6FF
local C_VALUE  = 0x00A6FF
local C_DIM    = 0x004477
local C_PANEL  = 0x001111
local C_POS    = 0x00A6FF
local C_NEG    = 0xFF00FF
local C_SEP    = 0x003355

-- ── Module API ───────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    return true
end

function M.start() end
function M.update() end
function M.stop() end
function M.handleKey(char, code)
    if code == keyboard.keys.delete then
        local stocker = getStocker()
        if stocker and stocker.clearHistory then
            stocker.clearHistory()
        end
    end
end

-- ── drawUI ───────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    local power  = getPower()
    local status = (power and power.getStatus) and power.getStatus() or {
        energyPercent  = 0,
        euStored       = 0,
        euCapacity     = 0,
        euNet          = 0,
        redstoneActive = false,
        lastUpdate     = "--:--:--",
        error          = "Power Control module unavailable",
    }
    local cfg = (power and power.config) or {
        checkInterval = 5, lowThreshold = 0.20, highThreshold = 0.90, redstoneSide = 1,
    }

    local pct   = status.energyPercent or 0
    local color = ui.getEnergyColor(pct, cfg.lowThreshold, cfg.highThreshold)

    -- Time estimates from net flow
    local netPerSec   = (status.euNet or 0) * 20
    local timeToFull  = (netPerSec >  1) and (status.euCapacity - status.euStored) / netPerSec  or nil
    local timeToEmpty = (netPerSec < -1) and  status.euStored                       / (-netPerSec) or nil

    -- Clear
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx  = x + 2
    local row = y

    -- ── Title ────────────────────────────────────────────────────────────────
    row = row + 1
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "LAPOTRONIC SUPERCAPACITOR")
    gpu.setForeground(C_DIM)
    gpu.set(x + w - 1 - #status.lastUpdate, row, status.lastUpdate)
    gpu.setForeground(C_SEP)
    local sepStart = cx + 26
    local sepEnd   = x + w - 2 - #status.lastUpdate - 1
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

    -- ── Data rows ────────────────────────────────────────────────────────────
    row = row + 2

    local function label(r, lbl, val, vc)
        gpu.setForeground(C_LABEL)
        gpu.setBackground(0x000000)
        gpu.set(cx, r, lbl)
        gpu.setForeground(vc or C_VALUE)
        gpu.set(cx + 11, r, val)
    end

    label(row, "STORED    ",
        ui.formatEU(status.euStored) .. "  /  " .. ui.formatEU(status.euCapacity))
    row = row + 2

    local netColor = (status.euNet or 0) >= 0 and C_POS or C_NEG
    label(row, "NET FLOW  ", string.format("%+.0f EU/t", status.euNet or 0), netColor)
    row = row + 1

    local col2 = cx + 30
    label(row, "FULL IN   ", ui.formatTime(timeToFull))
    gpu.setForeground(C_LABEL)
    gpu.set(col2, row, "EMPTY IN  ")
    gpu.setForeground(C_VALUE)
    gpu.set(col2 + 10, row, ui.formatTime(timeToEmpty))

    -- ── Separator ────────────────────────────────────────────────────────────
    row = row + 2
    gpu.setForeground(C_SEP)
    gpu.fill(cx, row, w - 4, 1, "─")

    -- ── Redstone section ─────────────────────────────────────────────────────
    row = row + 2
    gpu.setForeground(C_LABEL)
    gpu.set(cx, row, "REDSTONE  ")
    local badgeBg  = status.redstoneActive and 0xAA0000 or 0x222233
    local badgeTxt = status.redstoneActive and " ACTIVE " or "INACTIVE"
    gpu.setForeground(C_VALUE)
    gpu.setBackground(badgeBg)
    gpu.set(cx + 10, row, " " .. badgeTxt .. " ")
    gpu.setBackground(0x000000)
    gpu.setForeground(C_DIM)
    gpu.set(cx + 22, row, string.format(
        "ON >%.0f%%  ·  OFF <%.0f%%  ·  Side: %d",
        cfg.highThreshold * 100, cfg.lowThreshold * 100, cfg.redstoneSide))

    -- ── Crafting History ─────────────────────────────────────────────────────
    row = row + 2
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "CRAFTING HISTORY")
    gpu.setForeground(C_SEP)
    local hsepStart = cx + 17
    local hsepEnd   = x + w - 2
    if hsepEnd > hsepStart then
        gpu.fill(hsepStart, row, hsepEnd - hsepStart, 1, "─")
    end

    local stocker = getStocker()
    local hist = (stocker and stocker.getHistory) and stocker.getHistory() or {}
    local histStart = row + 2
    local histEnd   = y + h - 3
    local maxRows   = math.max(0, histEnd - histStart + 1)
    local startIdx  = math.max(1, #hist - maxRows + 1)
    local rightW    = 16
    local labelW    = w - 4 - 9 - rightW - 1

    for i = startIdx, #hist do
        local e = hist[i]
        local r = histStart + (i - startIdx)
        if r > histEnd then break end
        gpu.setForeground(C_DIM)
        gpu.set(cx, r, e.when)
        gpu.setForeground(C_VALUE)
        gpu.set(cx + 9, r, unicode.sub(e.label, 1, labelW))
        local statusColor = (e.status == "done")   and 0x44CC44
                         or (e.status == "queued") and 0xBBAA22
                         or 0xBB3333
        gpu.setForeground(statusColor)
        local right = string.format("%5dx %-7s", e.amount, e.status:sub(1, 7))
        gpu.set(x + w - 1 - rightW, r, right)
    end

    -- ── Footer hint ──────────────────────────────────────────────────────────
    local nextIn = (stocker and stocker.getNextCheckIn) and stocker.getNextCheckIn() or nil
    local stockStr
    if nextIn == nil then
        stockStr = "Stock: no ME"
    elseif nextIn == 0 then
        stockStr = "Stock: checking..."
    else
        stockStr = string.format("Stock: %ds", nextIn)
    end
    -- Memory indicator: free / total KB. Helpful when diagnosing OOM.
    local computer = require("computer")
    local memFree  = math.floor(computer.freeMemory() / 1024)
    local memTotal = math.floor(computer.totalMemory() / 1024)
    local memStr   = string.format("Mem: %d/%d KB", memFree, memTotal)

    gpu.setForeground(C_DIM)
    gpu.set(cx, y + h - 1,
        string.format("Interval: %ds  %s  %s  [Del] Clear  [Q] Quit  [Tab] Switch",
            cfg.checkInterval, stockStr, memStr))

    -- ── Error overlay ────────────────────────────────────────────────────────
    if status.error then
        gpu.setForeground(C_NEG)
        gpu.set(cx, y + h - 2, ("ERR: " .. status.error):sub(1, w - 4))
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

return M
