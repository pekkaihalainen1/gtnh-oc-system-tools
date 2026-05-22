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
local CRAFT_TIMEOUT = 7200  -- absolute backstop: 2 real hours before declaring dead
local STALL_WINDOW  = 2400  -- 40 real min (~2 Minecraft days) of no stock movement = stalled

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
    inStock      = {},  -- itemKey -> current count, updated each check cycle
}

local _patsByKey    = {}  -- itemKey -> craftable object cache
local _pendingJobs  = {}  -- itemKey -> {job, requestedAt, amount}
                          -- cleared when job finishes, cancels, or times out
local _epochOffset  = nil -- realUnixTime - computer.uptime() after NTP sync

local PATTERN_REFRESH_THROTTLE = 60  -- seconds between automatic pattern refreshes
local _lastPatternRefresh = -math.huge

-- Set to true after we confirm the ME interface accepts a filter table on
-- getItemsInNetwork. Targeted queries avoid the multi-MB full-network
-- snapshot that bulk scans produce on large GTNH bases.
local _useFilteredScan = nil  -- nil = unprobed, true = supported, false = bulk fallback

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

-- Inverse of itemKey: split "modid:item_name:damage" back into (name, damage).
-- The damage is always the part after the LAST colon, so item names with
-- their own colons (modid:item) are preserved correctly.
local function parseKey(key)
    local lastColon = nil
    for i = #key, 1, -1 do
        if key:sub(i, i) == ":" then lastColon = i; break end
    end
    if lastColon then
        return key:sub(1, lastColon - 1), tonumber(key:sub(lastColon + 1)) or 0
    end
    return key, 0
end

local function clampScroll(cursor, scrollOff, visible)
    if cursor < scrollOff + 1           then scrollOff = cursor - 1 end
    if cursor > scrollOff + visible     then scrollOff = cursor - visible end
    if scrollOff < 0                    then scrollOff = 0 end
    return scrollOff
end

-- ── Real-time helpers (must be defined before addHistory uses them) ──────────

local function syncRealTime()
    if not component.isAvailable("internet") then return end
    local ok, handle = pcall(component.internet.request, "http://worldtimeapi.org/api/ip")
    if not ok then return end
    local deadline = computer.uptime() + 8
    local status
    repeat
        status = handle.response()
        if not status then os.sleep(0.1) end
    until status or computer.uptime() > deadline
    if status ~= 200 then handle.close(); return end
    local body = {}
    while true do
        local chunk = handle.read(8192)
        if not chunk then break end
        body[#body + 1] = chunk
    end
    handle.close()
    local unixtime = tonumber(table.concat(body):match('"unixtime":(%d+)'))
    if unixtime then
        _epochOffset = unixtime - computer.uptime()
    end
end

local function realTimeStr()
    if not _epochOffset then
        return os.date("%H:%M:%S")  -- fallback: Minecraft time
    end
    local t = math.floor(_epochOffset + computer.uptime())
    return string.format("%02d:%02d:%02d", math.floor(t / 3600) % 24, math.floor(t / 60) % 60, t % 60)
end

local _historySeq = 0

-- Add a fresh entry to the ring buffer. Returns the entry id so the caller
-- can later update the same row in place (see updateHistoryStatus).
local function addHistory(label, amount, status)
    _historySeq = _historySeq + 1
    state.history[state.histHead] = {
        id     = _historySeq,
        label  = unicode.sub(tostring(label), 1, 20),
        amount = amount,
        status = status,
        when   = realTimeStr(),
    }
    state.histHead  = (state.histHead % HISTORY_MAX) + 1
    state.histCount = math.min(state.histCount + 1, HISTORY_MAX)
    return _historySeq
end

-- Update an existing entry's status in place (e.g., "queued" -> "done").
-- The original timestamp is preserved so the log keeps request-time order.
-- Returns true if found, false if the entry was already overwritten by the
-- ring buffer; in that case the caller should fall back to addHistory.
local function updateHistoryStatus(id, status)
    if not id then return false end
    for i = 1, HISTORY_MAX do
        local e = state.history[i]
        if e and e.id == id then
            e.status = status
            return true
        end
    end
    return false
end

local function getHistoryOrdered()
    local result = {}
    if state.histCount == 0 then return result end
    -- Walk backwards from most-recent, fill result from end so oldest is at [1]
    local idx = (state.histHead - 2) % HISTORY_MAX + 1
    for i = state.histCount, 1, -1 do
        result[i] = state.history[idx]
        idx = (idx - 2) % HISTORY_MAX + 1
    end
    return result
end

function M.getHistory()
    return getHistoryOrdered()
end

function M.clearHistory()
    state.history  = {}
    state.histHead = 1
    state.histCount = 0
    -- Detach in-flight jobs from now-deleted history rows; resolution
    -- will fall through to addHistory and log a fresh entry.
    for _, pending in pairs(_pendingJobs) do
        pending.historyId = nil
    end
end

function M.getNextCheckIn()
    if not state.me then return nil end
    local remaining = (state.lastCheck + M.config.checkInterval) - computer.uptime()
    return math.max(0, math.floor(remaining))
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
                newPats[#newPats + 1] = { key = k, label = tostring(label) }
                newByKey[k] = c
            end
        end
    end
    table.sort(newPats, function(a, b) return a.label:lower() < b.label:lower() end)
    state.patterns = newPats
    _patsByKey     = newByKey
    _lastPatternRefresh = computer.uptime()
    rebuildFilteredPatterns()
    -- Free the old craftable userdata refs and any transient garbage
    collectgarbage("collect")
end

-- Throttled variant for automatic recovery paths (stall/timeout).
-- Avoids burning memory rebuilding the entire pattern cache every cycle
-- when many items stall back-to-back. Home key still uses refreshPatterns
-- directly to bypass the throttle.
local function refreshPatternsThrottled()
    if computer.uptime() - _lastPatternRefresh < PATTERN_REFRESH_THROTTLE then return end
    pcall(refreshPatterns)
end

-- Returns a completion status string, or nil if still running.
-- Stock-based detection only. The AE2 OC API's hasFailed() lies in this
-- version (returns true for jobs that are crafting AND for completed
-- ones), so we ignore it entirely. isDone() is trusted only when it
-- says "true" — we treat "false" as "no information" and rely on stock.
local function jobStatus(pending, current, level)
    local now = computer.uptime()

    if current >= level then return "done" end

    -- Trust isDone() only when positive (fast-path completion)
    if pending.job then
        local okD, done = pcall(function() return pending.job.isDone() end)
        if okD and done then return "done" end
    end

    -- Any stock change = network is alive; reset stall timer
    pending.lastSeenStock = pending.lastSeenStock or current
    if current ~= pending.lastSeenStock then
        pending.lastSeenStock  = current
        pending.lastProgressAt = now
    end

    if now - (pending.lastProgressAt or pending.requestedAt) > STALL_WINDOW then
        return "stalled"
    end

    if now - pending.requestedAt > CRAFT_TIMEOUT then return "timeout" end

    return nil
end

-- Process a single stocked item. Isolated from other items so a thrown
-- error here cannot block siblings. Returns nothing meaningful.
local function processItem(key, entry, current)
    if not (entry.level and entry.level > 0) then return end

    -- Resolve pending job if there is one
    if _pendingJobs[key] then
        local pending = _pendingJobs[key]
        local s = jobStatus(pending, current, entry.level)
        if s then
            -- Update the existing "queued" row in place so a single line
            -- transitions queued -> done/stalled/timeout. Fall back to
            -- a new entry if the original row was overwritten by the ring.
            if not updateHistoryStatus(pending.historyId, s) then
                addHistory(entry.label or key, pending.amount, s)
            end
            _pendingJobs[key] = nil
            -- A stall/timeout may indicate a stale craftable reference.
            -- Refresh patterns so the next request uses a fresh object.
            -- Throttled so back-to-back stalls do not thrash memory.
            if s == "stalled" or s == "timeout" then
                refreshPatternsThrottled()
            end
        else
            return  -- still running, leave it alone
        end
    end

    if current >= entry.level then return end

    local deficit = entry.level - current
    local amount  = (entry.perCycle and entry.perCycle > 0)
                    and math.min(deficit, entry.perCycle)
                    or  deficit
    local craftable = _patsByKey[key]
    if not craftable then
        addHistory(entry.label or key, amount, "no pattern")
        return
    end

    -- Original working signature first; fall back to alternates if needed.
    local ok, job = pcall(function() return craftable.request(amount, true, nil) end)
    if not ok or job == nil then
        ok, job = pcall(function() return craftable.request(amount, false) end)
    end
    if not ok or job == nil then
        ok, job = pcall(function() return craftable.request(amount) end)
    end
    -- Last resort: ME-level requestCrafting using the parsed key
    if not ok or job == nil then
        local name, damage = parseKey(key)
        ok, job = pcall(function()
            return state.me.requestCrafting({name = name, damage = damage}, amount)
        end)
    end

    if ok and job ~= nil then
        local now = computer.uptime()
        local hid = addHistory(entry.label or key, amount, "queued")
        _pendingJobs[key] = {
            job            = job,
            requestedAt    = now,
            amount         = amount,
            lastSeenStock  = current,
            lastProgressAt = now,
            historyId      = hid,
        }
    else
        addHistory(entry.label or key, amount, "err")
    end
end

local function checkAndStock()
    -- Build current stock counts. We MUST avoid a bulk getItemsInNetwork()
    -- call on large bases — that materializes a snapshot of every item in
    -- the network (often >1 MB) which spikes the OC Lua heap on every cycle.
    -- Prefer per-item filtered queries; fall back to one bulk scan only if
    -- the API rejects the filter table.
    local inStock = {}

    if _useFilteredScan ~= false then
        local allOk = true
        for key, _ in pairs(M.config.stockList) do
            local name, damage = parseKey(key)
            local ok, result = pcall(function()
                return state.me.getItemsInNetwork({name = name, damage = damage})
            end)
            if not ok or type(result) ~= "table" then
                allOk = false
                break
            end
            local total = 0
            for _, item in pairs(result) do
                if type(item) == "table" and item.name == name then
                    total = total + (item.size or 0)
                end
            end
            inStock[key] = total
            result = nil
        end
        if allOk then
            _useFilteredScan = true
        else
            _useFilteredScan = false
            inStock = {}
        end
    end

    if _useFilteredScan == false then
        -- Bulk fallback: scan everything once, then drop the snapshot.
        local wanted = {}
        for key, _ in pairs(M.config.stockList) do wanted[key] = true end
        local items = state.me.getItemsInNetwork() or {}
        for _, item in pairs(items) do
            if type(item) == "table" and item.name then
                local k = itemKey(item.name, item.damage)
                if wanted[k] then
                    inStock[k] = item.size or 0
                end
            end
        end
        items = nil
    end

    state.inStock = inStock

    -- Isolate each item: a thrown error processing one must not prevent
    -- the others from being processed in the same cycle.
    for key, entry in pairs(M.config.stockList) do
        local current = inStock[key] or 0
        local ok, err = pcall(processItem, key, entry, current)
        if not ok then
            addHistory(entry.label or key, 0, "err")
            _pendingJobs[key] = nil  -- prevent permanent block on a bad job
        end
    end

    -- Reclaim per-cycle garbage (network snapshot, transient closures, etc.)
    collectgarbage("collect")
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
    pcall(syncRealTime)
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

    local okS, errS = pcall(checkAndStock)

    if okS then
        state.error = nil
    else
        state.error = tostring(errS)
    end
    state.lastUpdate = realTimeStr()
end

function M.stop() end

-- ── drawUI ────────────────────────────────────────────────────────────────────

function M.drawUI(gpu, x, y, w, h)
    -- Two-column layout: STOCKED | PATTERNS
    local colAW = math.floor((w - 1) * 0.38)
    local colBW = w - colAW - 1
    local colBX = x + colAW + 1

    -- Compute layout rows
    local LIST_START = y + 4
    local LIST_END   = y + h - 13
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

    -- Single vertical separator
    gpu.setForeground(C_SEP)
    gpu.fill(colBX - 1, y + 2, 1, h - 14, "\xE2\x94\x82")

    -- Sub-separator on stocked column only
    gpu.fill(x, searchRow, colAW, 1, "\xE2\x94\x80")

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
                    local marker  = isCursor and "\xE2\x96\xB6 " or "  "  -- "▶ "
                    local pending = _pendingJobs[item.key]
                    local right
                    if pending then
                        local age = math.floor(computer.uptime() - pending.requestedAt)
                        right = string.format("wait %ds", age)
                    else
                        local cur = state.inStock[item.key] or 0
                        right = string.format("%d/%d", cur, item.level)
                    end
                    local lw   = pw - #marker - #right - 1
                    local lbl  = unicode.sub(item.label, 1, lw)
                    local line = marker .. lbl .. string.rep(" ", lw - unicode.len(lbl)) .. " " .. right
                    gpu.setForeground(pending and C_NEG or (isCursor and C_LABEL or C_VALUE))
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
    drawList("stocked",  state.stockedList,  state.cursorStk, state.scrollStk, x,     colAW, LIST_START, listRows)
    drawList("patterns", state.filteredPats, state.cursorPat, state.scrollPat, colBX, colBW, LIST_START, listRows)

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
        gpu.set(x + 2, er + 6, "[Enter] Next/Save  [Esc] Cancel  [Del] Remove item")

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
        "[Up/Down] Navigate  [Left/Right] Switch  [Enter] Edit  [Del] Clear pending  [Type] Search  [Esc] Clear  [Home] Refresh  [Q] Quit")

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
        elseif code == keyboard.keys.enter then
            if state.editorField == "level" then
                state.editorLevel = tonumber(state.editorBuf) or 0
                state.editorBuf   = state._editorPerCycle or "1"
                state.editorField = "perCycle"
            else
                closeEditor(true)
            end
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
    elseif code == keyboard.keys.delete then
        if state.activePanel == "stocked" and state.stockedList[state.cursorStk] then
            _pendingJobs[state.stockedList[state.cursorStk].key] = nil
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
    elseif code == keyboard.keys.home then
        if state.me then
            pcall(refreshPatterns)
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
