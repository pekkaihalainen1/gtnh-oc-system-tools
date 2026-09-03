-- History module: read-only crafting history feed for the Stock Maintainer
-- system. Has no logic of its own; pulls data from item_stocker via its
-- public accessors. Ported from the CRAFTING HISTORY section of
-- modules/dashboard.lua so the main system's dashboard stays untouched.
local unicode  = require("unicode")
local keyboard = require("keyboard")
local computer = require("computer")
local ui       = require("lib/ui")

local M = {}
M.id     = "history"
M.name   = "History"
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

-- ── Colors (mirror dashboard/item_stocker palette) ───────────────────────────

local C_TITLE = 0xFF00FF
local C_LABEL = 0x00A6FF
local C_VALUE = 0x00A6FF
local C_DIM   = 0x004477
local C_NEG   = 0xFF00FF
local C_SEP   = 0x003355

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
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx = x + 2

    -- ── Title ────────────────────────────────────────────────────────────────
    gpu.setForeground(C_TITLE)
    gpu.set(cx, y, "CRAFTING HISTORY")
    gpu.setForeground(C_SEP)
    local sepStart = cx + 17
    local sepEnd   = x + w - 2
    if sepEnd > sepStart then
        gpu.fill(sepStart, y, sepEnd - sepStart, 1, "─")
    end

    local stocker   = getStocker()
    local hist      = (stocker and stocker.getHistory) and stocker.getHistory() or {}
    local histStart = y + 2
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
        local statusColor = (e.status == "done")    and 0x44CC44   -- green
                         or (e.status == "queued")  and 0xBBAA22   -- dull yellow (awaiting confirm)
                         or (e.status == "running") and 0xBBAA22   -- dull yellow (confirmed active)
                         or 0xBB3333                                -- dull red (err/stalled/timeout/cancelled/failed)
        gpu.setForeground(statusColor)
        local right
        if ui.isDrop(e.label) then
            right = string.format("%6s %-7s", ui.formatDrop(e.amount), e.status:sub(1, 7))
        else
            right = string.format("%5dx %-7s", e.amount, e.status:sub(1, 7))
        end
        gpu.set(x + w - 1 - rightW, r, right)
    end

    -- ── Footer ────────────────────────────────────────────────────────────────
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
    local memFree  = math.floor(computer.freeMemory() / 1024)
    local memTotal = math.floor(computer.totalMemory() / 1024)
    local memStr   = string.format("Mem: %d/%d KB", memFree, memTotal)

    gpu.setForeground(C_SEP)
    gpu.fill(cx, y + h - 2, w - 4, 1, "─")

    gpu.setForeground(C_DIM)
    gpu.set(cx, y + h - 1,
        string.format("%s  %s  [Del] Clear  [Q] Quit  [Tab] Switch", stockStr, memStr))

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

return M
