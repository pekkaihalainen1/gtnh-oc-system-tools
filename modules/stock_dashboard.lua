-- Stock Dashboard module: read-only overview of featured stock levels for
-- the Stock Maintainer system (no power/redstone control). Has no logic of
-- its own; pulls data from item_stocker via its public accessors. Items are
-- "featured" by pressing [F] on a row in the Item Stocker's STOCKED list.
local unicode  = require("unicode")
local keyboard = require("keyboard")
local computer = require("computer")
local ui       = require("lib/ui")

local M = {}
M.id     = "stock_dashboard"
M.name   = "Dashboard"
M.config = {}

-- ── Cross-module lazy reference ──────────────────────────────────────────────

local _stocker = nil

local function getStocker()
    if not _stocker then
        local ok, m = pcall(require, "modules/item_stocker")
        if ok and m then _stocker = m end
    end
    return _stocker
end

-- ── Colors ────────────────────────────────────────────────────────────────────

local C_TITLE = 0xFF00FF
local C_LABEL = 0x00A6FF
local C_VALUE = 0x00A6FF
local C_DIM   = 0x004477
local C_SEP   = 0x003355
local C_PANEL = 0x0D0D1A
local C_NEG   = 0xFF00FF

-- Status square colors, matching the palette already used for crafting
-- history rows in dashboard.lua/history.lua.
local STATE_COLOR = {
    ok      = 0x00DD44,  -- green:  at/above target
    active  = 0xBBAA22,  -- yellow: queued/running
    problem = 0xBB3333,  -- red:    recent failure/cancel cooldown
    idle    = 0x666666,  -- gray:   below target, nothing happening yet
}

-- ── Column layout ─────────────────────────────────────────────────────────────

local LABEL_W   = 20
local PERCENT_W = 4   -- "100%" / " 72%"
local RIGHT_W   = 14  -- "1440/2000" or "9.5KL/10KL"
local STATUS_W  = 3   -- " ■ "

-- ── Module API ───────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    return true
end

function M.start() end
function M.update() end
function M.stop() end
function M.handleKey(char, code) end

-- ── drawUI ───────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    local stocker = getStocker()
    local featured = (stocker and stocker.getFeaturedStock) and stocker.getFeaturedStock() or {}

    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx  = x + 2
    local row = y

    -- ── Title ────────────────────────────────────────────────────────────────
    row = row + 1
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "STOCK DASHBOARD")
    gpu.setForeground(C_SEP)
    local sepStart = cx + 16
    local sepEnd   = x + w - 2
    if sepEnd > sepStart then
        gpu.fill(sepStart, row, sepEnd - sepStart, 1, "─")
    end

    row = row + 2
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "FEATURED STOCK")
    gpu.setForeground(C_DIM)
    local countStr = string.format("(%d)", #featured)
    gpu.set(x + w - 1 - #countStr, row, countStr)

    row = row + 1
    gpu.setForeground(C_SEP)
    gpu.fill(cx, row, w - 4, 1, "─")
    row = row + 1

    -- ── Bar rows ─────────────────────────────────────────────────────────────
    local barW = w - 4 - LABEL_W - 1 - 2 - PERCENT_W - 1 - RIGHT_W - 1 - STATUS_W
    if barW < 5 then barW = 5 end

    local FOOT_ROW  = y + h - 1
    local ERR_ROW   = y + h - 3
    local listEnd   = FOOT_ROW - 2
    local maxRows   = math.max(0, listEnd - row + 1)

    if #featured == 0 then
        gpu.setForeground(C_DIM)
        local hint = "No featured items. In Item Stocker, select a stocked item and press [F]."
        gpu.set(cx, row, unicode.sub(hint, 1, w - 4))
    end

    local shown = math.min(#featured, maxRows)
    for i = 1, shown do
        local item = featured[i]
        local r    = row + i - 1

        gpu.setForeground(C_VALUE)
        local lbl = unicode.sub(item.label, 1, LABEL_W)
        gpu.set(cx, r, lbl .. string.rep(" ", LABEL_W - unicode.len(lbl)))

        local barX = cx + LABEL_W + 1
        local filled = math.floor(barW * math.max(0, math.min(1, item.percent)))
        gpu.setForeground(C_DIM)
        gpu.set(barX, r, "[")
        if filled > 0 then
            gpu.setBackground(STATE_COLOR[item.state] or C_DIM)
            gpu.fill(barX + 1, r, filled, 1, " ")
        end
        if filled < barW then
            gpu.setBackground(C_PANEL)
            gpu.fill(barX + 1 + filled, r, barW - filled, 1, " ")
        end
        gpu.setBackground(0x000000)
        gpu.setForeground(C_DIM)
        gpu.set(barX + 1 + barW, r, "]")

        local pctX = barX + 2 + barW
        gpu.setForeground(C_VALUE)
        gpu.set(pctX, r, string.format("%3.0f%%", item.percent * 100))

        local rightStr
        if item.isFluid then
            rightStr = ui.formatDrop(item.current) .. "/" .. ui.formatDrop(item.level)
        else
            rightStr = string.format("%d/%d", item.current, item.level)
        end
        local rightX = pctX + PERCENT_W + 1
        gpu.set(rightX, r, string.format("%" .. RIGHT_W .. "s", unicode.sub(rightStr, 1, RIGHT_W)))

        local sqX = rightX + RIGHT_W + 1
        gpu.setForeground(STATE_COLOR[item.state] or C_DIM)
        gpu.set(sqX, r, "\xE2\x96\xA0")  -- "■"
    end

    if #featured > shown then
        gpu.setForeground(C_DIM)
        gpu.set(cx, row + shown, string.format("+%d more not shown", #featured - shown))
    end

    -- ── Footer ────────────────────────────────────────────────────────────────
    local memFree  = math.floor(computer.freeMemory() / 1024)
    local memTotal = math.floor(computer.totalMemory() / 1024)
    local memStr   = string.format("Mem: %d/%d KB", memFree, memTotal)

    gpu.setForeground(C_SEP)
    gpu.fill(cx, FOOT_ROW - 1, w - 4, 1, "─")
    gpu.setForeground(C_DIM)
    gpu.set(cx, FOOT_ROW, string.format("%s  [Tab] Switch  [Q] Quit", memStr))

    -- ── Error overlay ────────────────────────────────────────────────────────
    if not (stocker and stocker.getFeaturedStock) then
        gpu.setForeground(C_NEG)
        gpu.set(cx, ERR_ROW, "ERR: Item Stocker module unavailable")
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

return M
