-- Auto Item Stocker module for AE2 ME system
-- Reads craftable patterns, maintains configured stock levels by requesting crafts.
local component = require("component")
local computer  = require("computer")
local keyboard  = require("keyboard")
local os        = require("os")
local unicode   = require("unicode")

local M = {}
M.id   = "item_stocker"
M.name = "Item Stocker"

M.config = {
    checkInterval = 10,
    stockList     = {},  -- [itemKey] = {level, perCycle, label}
}

-- ── Colors ────────────────────────────────────────────────────────────────────

local C_TITLE = 0xFF00FF
local C_LABEL = 0x00A6FF
local C_VALUE = 0x00A6FF
local C_DIM   = 0x004477
local C_SEP   = 0x003355
local C_POS   = 0x00A6FF
local C_NEG   = 0xFF00FF
local C_ACT   = 0x002244

-- ── Constants ─────────────────────────────────────────────────────────────────

local HISTORY_MAX  = 30
local VISIBLE_ROWS = 32
local CRAFT_TIMEOUT = 300  -- seconds before assuming a stuck job is dead

-- ── State ─────────────────────────────────────────────────────────────────────

local state = {
    me           = nil,
    patterns     = {},
    filteredPats = {},
    stockedList  = {},
    activePanel  = "patterns",
    cursorStk    = 1,
    cursorPat    = 1,
    scrollStk    = 0,
    scrollPat    = 0,
    searchStr    = "",
    editorMode   = false,
    editorKey    = nil,
    editorLabel  = "",
    editorField  = "level",
    editorBuf    = "",
    editorLevel  = 0,
    history      = {},
    histHead     = 1,
    histCount    = 0,
    lastCheck    = 0,
    lastUpdate   = "--:--:--",
    screenW      = 0,
    screenH      = 0,
    error        = nil,
}

local _patsByKey    = {}  -- itemKey -> craftable object cache
local _pendingJobs  = {}  -- itemKey -> {job, requestedAt, amount}
                          -- cleared when job finishes, cancels, or times out

-- ── Helpers ───────────────────────────────────────────────────────────────────

local _cfg = require("lib/config")

local function saveMyConfig()
    local full = _cfg.load("config.cfg", {})
    full[M.id] = M.config
    _cfg.save("config.cfg", full)
end

local function itemKey(name, damage)
    return tostring(name) .. ":" .. tostring(damage or 0)
end

local function clampScroll(cursor, scrollOff, visible)
    if cursor < scrollOff + 1           then scrollOff = cursor - 1 end
    if cursor > scrollOff + visible     then scrollOff = cursor - visible end
    if scrollOff < 0                    then scrollOff = 0 end
    return scrollOff
end

local function addHistory(label, amount, status)
    state.history[state.histHead] = {
        label  = unicode.sub(tostring(label), 1, 20),
        amount = amount,
        status = status,
        when   = os.date("%H:%M:%S"),
    }
    state.histHead  = (state.histHead % HISTORY_MAX) + 1
    state.histCount = math.min(state.histCount + 1, HISTORY_MAX)
end

local function getHistoryOrdered()
    local result = {}
    if state.histCount == 0 then return result end
    local idx = (state.histHead - 2) % HISTORY_MAX + 1
    for i = 1, state.histCount do
        result[i] = state.history[idx]
        idx = (idx - 2) % HISTORY_MAX + 1
    end
    return result
end

local function rebuildStockedList()
    state.stockedList = {}
    for key, entry in pairs(M.config.stockList) do
        table.insert(state.stockedList, {
            key      = key,
            label    = entry.label or key,
            level    = entry.level or 0,
            perCycle = entry.perCycle or 0,
        })
    end
    table.sort(state.stockedList, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    state.cursorStk = math.max(1, math.min(state.cursorStk, math.max(1, #state.stockedList)))
end

local function rebuildFilteredPatterns()
    if state.searchStr == "" then
        state.filteredPats = state.patterns
    else
        local q = state.searchStr:lower()
        state.filteredPats = {}
        for _, p in ipairs(state.patterns) do
            if p.label:lower():find(q, 1, true) then
                state.filteredPats[#state.filteredPats + 1] = p
            end
        end
    end
    state.cursorPat = math.max(1, math.min(state.cursorPat, math.max(1, #state.filteredPats)))
    state.scrollPat = clampScroll(state.cursorPat, state.scrollPat, VISIBLE_ROWS)
end

-- ── Component helpers ─────────────────────────────────────────────────────────

local function extractItemInfo(c)
    -- Try getItemStack() method (some AE2 OC versions)
    local ok, stack = pcall(function() return c.getItemStack() end)
    if ok and type(stack) == "table" and stack.label then
        return stack.label, stack.name, stack.damage
    end
    -- Try direct fields (plain table or proxy with string properties)
    local label  = type(c.label)  == "string" and c.label  or nil
    local name   = type(c.name)   == "string" and c.name   or nil
    local damage = type(c.damage) == "number" and c.damage or 0
    return label, name, damage
end

local function refreshPatterns()
    local list = state.me.getCraftables() or {}
    local newPats  = {}
    local newByKey = {}
    -- Use pairs: AE2 OC may return a non-sequential table
    for _, c in pairs(list) do
        if type(c) == "table" or type(c) == "userdata" then
            local label, name, damage = extractItemInfo(c)
            if label then
                local k = itemKey(name or "unknown", damage or 0)
                newPats[#newPats + 1] = { key = k, label = tostring(label), craftable = c }
                newByKey[k] = c
            end
        end
    end
    table.sort(newPats, function(a, b) return a.label:lower() < b.label:lower() end)
    state.patterns = newPats
    _patsByKey     = newByKey
    rebuildFilteredPatterns()
end

local function jobFinished(pending, current, level)
    if current >= level then return true end
    if computer.uptime() - pending.requestedAt > CRAFT_TIMEOUT then return true end
    if pending.job then
        local ok, done = pcall(function() return pending.job.isDone() end)
        if ok and done then return true end
        local ok2, cancelled = pcall(function() return pending.job.isCanceled() end)
        if ok2 and cancelled then return true end
    end
    return false
end

local function checkAndStock()
    local inStock = {}
    local items = state.me.getItemsInNetwork() or {}
    for _, item in pairs(items) do
        if type(item) == "table" and item.name then
            inStock[itemKey(item.name, item.damage)] = item.size or 0
        end
    end

    for key, entry in pairs(M.config.stockList) do
        if entry.level and entry.level > 0 then
            local current = inStock[key] or 0

            -- Clear finished jobs so we can request again
            if _pendingJobs[key] and jobFinished(_pendingJobs[key], current, entry.level) then
                _pendingJobs[key] = nil
            end

            -- Skip if a job is still running
            if _pendingJobs[key] then goto continue end

            if current < entry.level then
                local deficit = entry.level - current
                local amount  = (entry.perCycle and entry.perCycle > 0)
                                and math.min(deficit, entry.perCycle)
                                or  deficit
                local craftable = _patsByKey[key]
                if not craftable then
                    addHistory(entry.label or key, amount, "no pattern")
                else
                    local ok, job = pcall(function()
                        return craftable.request(amount, true, nil)
                    end)
                    if not ok then
                        local ok2, job2 = pcall(function()
                            return state.me.requestCrafting(
                                {name=entry.name, damage=entry.damage}, amount)
                        end)
                        ok, job = ok2, job2
                    end
                    if ok then
                        _pendingJobs[key] = {
                            job         = job,
                            requestedAt = computer.uptime(),
                            amount      = amount,
                        }
                        addHistory(entry.label or key, amount, "queued")
                    else
                        addHistory(entry.label or key, amount, "err")
                    end
                end
            end

            ::continue::
        end
    end
end

-- ── Editor helpers ────────────────────────────────────────────────────────────

local function openEditor(key, label)
    local existing = M.config.stockList[key] or {}
    state.editorMode  = true
    state.editorKey   = key
    state.editorLabel = label or key
    state.editorField = "level"
    state.editorLevel = existing.level or 0
    state.editorBuf   = tostring(existing.level or 0)
    -- store perCycle for Tab switch
    state._editorPerCycle = tostring(existing.perCycle or 1)
end

local function closeEditor(save)
    if save and state.editorKey then
        local lvl = tonumber(state.editorLevel) or 0
        local pc  = tonumber(state._editorPerCycle) or 1
        if state.editorField == "level" then
            lvl = tonumber(state.editorBuf) or 0
        else
            pc  = tonumber(state.editorBuf) or 0
        end
        M.config.stockList[state.editorKey] = {
            level    = math.max(0, math.floor(lvl)),
            perCycle = math.max(0, math.floor(pc)),
            label    = state.editorLabel,
        }
        saveMyConfig()
        rebuildStockedList()
    end
    state.editorMode  = false
    state.editorKey   = nil
    state.editorLabel = ""
    state.editorBuf   = ""
    state._editorPerCycle = nil
end

local function removeFromStock(key)
    M.config.stockList[key] = nil
    saveMyConfig()
    rebuildStockedList()
end

-- ── Module API ────────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    state.screenW = screenW
    state.screenH = screenH
    if component.isAvailable("me_interface") then
        state.me = component.me_interface
    elseif component.isAvailable("me_controller") then
        state.me = component.me_controller
    else
        state.error = "No ME Interface found — connect one and restart"
    end
    rebuildStockedList()
    -- force immediate pattern load on first update()
    state.lastCheck = -math.huge
    -- also load right now if ME is already available
    if state.me then
        pcall(refreshPatterns)
    end
    return true  -- never fatal: power module must keep running
end

function M.start() end

function M.update()
    if not state.me then
        -- retry component discovery each cycle in case ME is connected later
        if component.isAvailable("me_interface") then
            state.me = component.me_interface
            state.error = nil
            state.lastCheck = -math.huge
        elseif component.isAvailable("me_controller") then
            state.me = component.me_controller
            state.error = nil
            state.lastCheck = -math.huge
        end
        return
    end

    local now = computer.uptime()
    if now - state.lastCheck < M.config.checkInterval then return end
    state.lastCheck = now

    local okP, errP = pcall(refreshPatterns)
    local okS, errS = pcall(checkAndStock)

    if okP and okS then
        state.error = nil
    else
        state.error = tostring(not okP and errP or errS)
    end
    state.lastUpdate = os.date("%H:%M:%S")
end

function M.stop() end

-- ── drawUI ────────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    -- Dynamic column widths based on actual screen width
    local colAW = math.floor((w - 2) / 3)
    local colBW = math.floor((w - 2) / 3)
    local colCW = w - colAW - colBW - 2
    local colBX = x + colAW + 1
    local colCX = colBX + colBW + 1

    -- Compute layout rows (relative to y)
    local LIST_START = y + 4        -- row where list items begin
    local LIST_END   = y + h - 13   -- last list row (leaves room for editor+footer)
    local visRows    = math.max(1, LIST_END - LIST_START + 1)
    local SEP1_ROW   = LIST_END + 1
    local ED_START   = SEP1_ROW + 1
    local FOOT_ROW   = y + h - 1
    local ERR_ROW    = y + h

    -- Clear
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    -- ── Title row ─────────────────────────────────────────────────────────────
    gpu.setForeground(C_TITLE)
    gpu.set(x + 2, y, "ITEM STOCKER")
    gpu.setForeground(C_DIM)
    gpu.set(x + w - 1 - #state.lastUpdate, y, state.lastUpdate)

    -- ── Full-width separator ──────────────────────────────────────────────────
    gpu.setForeground(C_SEP)
    gpu.fill(x, y + 1, w, 1, "\xE2\x94\x80")  -- "─"

    -- ── Panel headers row ────────────────────────────────────────────────────
    local headerRow = y + 2
    local searchRow = y + 3
    gpu.setForeground(C_TITLE)
    gpu.set(x + 1, headerRow, "STOCKED")
    gpu.set(colBX, headerRow, string.format("PATTERNS (%d)", #state.filteredPats))
    gpu.set(colCX, headerRow, "HISTORY")

    -- Vertical separators (full height)
    gpu.setForeground(C_SEP)
    gpu.fill(colBX - 1, y + 2, 1, h - 14, "\xE2\x94\x82")
    gpu.fill(colCX - 1, y + 2, 1, h - 14, "\xE2\x94\x82")

    -- Sub-separator on stocked and history columns only
    gpu.fill(x,      searchRow, colAW,  1, "\xE2\x94\x80")
    gpu.fill(colCX,  searchRow, colCW,  1, "\xE2\x94\x80")

    -- Search bar in patterns column
    local searchActive = (state.activePanel == "patterns") and not state.editorMode
    if searchActive then
        gpu.setBackground(C_ACT)
        gpu.setForeground(C_LABEL)
    else
        gpu.setBackground(0x000000)
        gpu.setForeground(C_DIM)
    end
    local searchPrefix = " Search: "
    local searchMaxW   = colBW - #searchPrefix - 1
    local searchText   = unicode.sub(state.searchStr, -searchMaxW)  -- show tail if long
    local searchLine   = searchPrefix .. searchText .. (searchActive and "_" or " ")
    gpu.set(colBX, searchRow, string.format("%-" .. colBW .. "s", searchLine):sub(1, colBW))
    gpu.setBackground(0x000000)

    -- ── STOCKED list ─────────────────────────────────────────────────────────
    local function drawList(panel, items, cursor, scrollOff, px, pw, startRow, rows)
        local isActive = (state.activePanel == panel)
        for i = 1, rows do
            local idx = scrollOff + i
            local r   = startRow + i - 1
            if r > startRow + rows - 1 then break end
            gpu.setBackground(0x000000)
            if items[idx] then
                local item = items[idx]
                local isCursor = isActive and (idx == cursor)
                if isCursor then
                    gpu.setBackground(C_ACT)
                    gpu.fill(px, r, pw, 1, " ")
                end
                if panel == "stocked" then
                    local marker = isCursor and "\xE2\x96\xB6 " or "  "  -- "▶ "
                    local right  = string.format("%5d/%d", item.level, item.perCycle)
                    local lw     = pw - #marker - #right - 1
                    local lbl    = unicode.sub(item.label, 1, lw)
                    local line   = marker .. lbl .. string.rep(" ", lw - unicode.len(lbl)) .. " " .. right
                    gpu.setForeground(isCursor and C_LABEL or C_VALUE)
                    gpu.set(px, r, line:sub(1, pw))
                else
                    -- patterns panel
                    local tracked = M.config.stockList[item.key] ~= nil
                    local marker  = isCursor and "\xE2\x96\xB6 " or (tracked and "\xE2\x97\x8F " or "  ")
                    local lw      = pw - #marker
                    local lbl     = unicode.sub(item.label, 1, lw)
                    local line    = marker .. lbl
                    gpu.setForeground(isCursor and C_LABEL or (tracked and C_POS or C_VALUE))
                    gpu.set(px, r, line:sub(1, pw))
                end
                gpu.setBackground(0x000000)
            end
        end
        -- fill remaining rows
    end

    local listRows = visRows
    drawList("stocked",  state.stockedList,  state.cursorStk, state.scrollStk, x,     colAW,  LIST_START, listRows)
    drawList("patterns", state.filteredPats, state.cursorPat, state.scrollPat, colBX, colBW,  LIST_START, listRows)

    -- ── HISTORY panel ─────────────────────────────────────────────────────────
    local hist = getHistoryOrdered()
    for i = 1, math.min(#hist, listRows) do
        local e = hist[i]
        local r = LIST_START + i - 1
        gpu.setForeground(C_DIM)
        gpu.set(colCX, r, e.when)
        gpu.setForeground(C_VALUE)
        local lbl = unicode.sub(e.label, 1, colCW - 18)
        gpu.set(colCX + 9, r, lbl)
        gpu.setForeground(e.status == "queued" and C_POS or C_NEG)
        local right = string.format("%5dx %-4s", e.amount, e.status:sub(1,4))
        gpu.set(colCX + colCW - #right, r, right)
        gpu.setBackground(0x000000)
    end

    -- ── Separator before editor ───────────────────────────────────────────────
    gpu.setForeground(C_SEP)
    gpu.fill(x, SEP1_ROW, w, 1, "\xE2\x94\x80")

    -- ── Stocking Editor ───────────────────────────────────────────────────────
    local er = ED_START
    if state.editorMode then
        gpu.setForeground(C_TITLE)
        gpu.set(x + 2, er, "STOCKING EDITOR")
        gpu.setForeground(C_VALUE)
        gpu.set(x + 18, er, unicode.sub(state.editorLabel, 1, w - 20))

        -- Level field
        local lvlLabel = "MAINTAIN LEVEL  : "
        gpu.setForeground(C_LABEL)
        gpu.set(x + 2, er + 2, lvlLabel)
        local lvlBuf = (state.editorField == "level") and state.editorBuf or tostring(state.editorLevel)
        if state.editorField == "level" then
            gpu.setBackground(C_ACT)
            gpu.setForeground(C_VALUE)
        else
            gpu.setBackground(0x000000)
            gpu.setForeground(C_DIM)
        end
        gpu.set(x + 2 + #lvlLabel, er + 2, string.format("%-12s", lvlBuf .. (state.editorField == "level" and "_" or "")))
        gpu.setBackground(0x000000)

        -- PerCycle field
        local pcLabel = "PER CYCLE CRAFT : "
        gpu.setForeground(C_LABEL)
        gpu.set(x + 2, er + 4, pcLabel)
        gpu.setForeground(C_DIM)
        gpu.set(x + 2 + #pcLabel + 14, er + 4, " (0=all needed)")
        local pcBuf = (state.editorField == "perCycle") and state.editorBuf or (state._editorPerCycle or "1")
        if state.editorField == "perCycle" then
            gpu.setBackground(C_ACT)
            gpu.setForeground(C_VALUE)
        else
            gpu.setBackground(0x000000)
            gpu.setForeground(C_DIM)
        end
        gpu.set(x + 2 + #pcLabel, er + 4, string.format("%-12s", pcBuf .. (state.editorField == "perCycle" and "_" or "")))
        gpu.setBackground(0x000000)

        -- Current stock hint
        gpu.setForeground(C_DIM)
        gpu.set(x + 2, er + 6, "[Tab] Switch field  [Enter] Save  [Esc] Cancel  [Del] Remove item")

    else
        gpu.setForeground(C_DIM)
        local hint = "Select an item and press Enter to configure stocking level"
        local hx   = x + math.floor((w - #hint) / 2)
        gpu.set(hx, er + 2, hint)
    end

    -- ── Footer ────────────────────────────────────────────────────────────────
    gpu.setForeground(C_SEP)
    gpu.fill(x, FOOT_ROW - 1, w, 1, "\xE2\x94\x80")
    gpu.setForeground(C_DIM)
    gpu.set(x + 2, FOOT_ROW,
        "[Up/Down] Navigate  [Left/Right] Switch panel  [Enter] Edit  [Type] Search patterns  [Esc] Clear search  [Q] Quit")

    -- ── Error overlay ─────────────────────────────────────────────────────────
    if state.error then
        gpu.setForeground(C_NEG)
        gpu.set(x + 2, ERR_ROW, ("ERR: " .. state.error):sub(1, w - 4))
    end

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

-- ── handleKey ─────────────────────────────────────────────────────────────────

function M.handleKey(char, code)
    if state.editorMode then
        -- Editor mode
        if char >= 48 and char <= 57 then  -- digits
            if #state.editorBuf < 9 then
                state.editorBuf = state.editorBuf .. string.char(char)
            end
        elseif code == keyboard.keys.back then
            state.editorBuf = state.editorBuf:sub(1, -2)
        elseif code == keyboard.keys.tab then
            if state.editorField == "level" then
                state.editorLevel = tonumber(state.editorBuf) or 0
                state.editorBuf   = state._editorPerCycle or "1"
                state.editorField = "perCycle"
            else
                state._editorPerCycle = state.editorBuf
                state.editorBuf       = tostring(state.editorLevel)
                state.editorField     = "level"
            end
        elseif code == keyboard.keys.enter then
            closeEditor(true)
        elseif code == keyboard.keys.escape then
            closeEditor(false)
        elseif code == keyboard.keys.delete then
            if state.editorKey then
                removeFromStock(state.editorKey)
            end
            closeEditor(false)
        end
        return
    end

    -- Navigation mode
    if code == keyboard.keys.up then
        if state.activePanel == "stocked" then
            state.cursorStk = math.max(1, state.cursorStk - 1)
            state.scrollStk = clampScroll(state.cursorStk, state.scrollStk, VISIBLE_ROWS)
        else
            state.cursorPat = math.max(1, state.cursorPat - 1)
            state.scrollPat = clampScroll(state.cursorPat, state.scrollPat, VISIBLE_ROWS)
        end
    elseif code == keyboard.keys.down then
        if state.activePanel == "stocked" then
            state.cursorStk = math.min(math.max(1, #state.stockedList), state.cursorStk + 1)
            state.scrollStk = clampScroll(state.cursorStk, state.scrollStk, VISIBLE_ROWS)
        else
            state.cursorPat = math.min(math.max(1, #state.filteredPats), state.cursorPat + 1)
            state.scrollPat = clampScroll(state.cursorPat, state.scrollPat, VISIBLE_ROWS)
        end
    elseif code == keyboard.keys.left then
        state.activePanel = "stocked"
    elseif code == keyboard.keys.right then
        state.activePanel = "patterns"
    elseif code == keyboard.keys.enter then
        if state.activePanel == "stocked" and state.stockedList[state.cursorStk] then
            local item = state.stockedList[state.cursorStk]
            openEditor(item.key, item.label)
        elseif state.activePanel == "patterns" and state.filteredPats[state.cursorPat] then
            local item = state.filteredPats[state.cursorPat]
            openEditor(item.key, item.label)
        end
    elseif code == keyboard.keys.escape then
        if state.searchStr ~= "" then
            state.searchStr = ""
            rebuildFilteredPatterns()
        end
    elseif code == keyboard.keys.back then
        if state.activePanel == "patterns" and #state.searchStr > 0 then
            state.searchStr = unicode.sub(state.searchStr, 1, unicode.len(state.searchStr) - 1)
            rebuildFilteredPatterns()
        end
    elseif char >= 32 and char < 127 and state.activePanel == "patterns" then
        state.searchStr = state.searchStr .. string.char(char)
        rebuildFilteredPatterns()
    end
end

-- ── handleTouch ───────────────────────────────────────────────────────────────

function M.handleTouch(x, y, button)
    -- Determine panel from x
    local w      = state.screenW
    local colAW  = math.floor((w - 2) / 3)
    local colBX  = 1 + colAW + 1
    local colCX  = colBX + math.floor((w - 2) / 3) + 1
    local LIST_START = 6  -- absolute row where list starts (y=2 module area + 4 offset)

    if x < colBX - 1 then
        state.activePanel = "stocked"
        local idx = (y - LIST_START) + state.scrollStk + 1
        if idx >= 1 and idx <= #state.stockedList then
            state.cursorStk = idx
            state.scrollStk = clampScroll(state.cursorStk, state.scrollStk, VISIBLE_ROWS)
        end
    elseif x < colCX - 1 then
        state.activePanel = "patterns"
        local idx = (y - LIST_START) + state.scrollPat + 1
        if idx >= 1 and idx <= #state.filteredPats then
            state.cursorPat = idx
            state.scrollPat = clampScroll(state.cursorPat, state.scrollPat, VISIBLE_ROWS)
        end
    end
end

return M
