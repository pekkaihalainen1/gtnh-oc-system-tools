-- Auto Item Stocker module for AE2 ME system
-- Reads craftable patterns, maintains configured stock levels by requesting crafts.
local component = require("component")
local computer  = require("computer")
local keyboard  = require("keyboard")
local os        = require("os")
local unicode   = require("unicode")
local ui        = require("lib/ui")

-- collectgarbage is not exposed as a global in some OpenComputers sandboxes
-- (GTNH 2.9.x among them); calling it directly throws. Use this guarded
-- wrapper everywhere instead so a missing collectgarbage is a harmless no-op.
local function gc()
    if type(collectgarbage) == "function" then collectgarbage("collect") end
end

local M = {}
M.id   = "item_stocker"
M.name = "Item Stocker"

M.config = {
    checkInterval = 10,
    stockList     = {},  -- [itemKey] = {level, perCycle, label}
    roundRobin    = false, -- rotate item processing order each cycle so no
                           -- single item permanently hogs free crafting CPUs
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
-- Max characters stored per history label. The dashboard clips to the actual
-- column width, so this only needs to be generous enough not to be the
-- bottleneck for long GTNH names (e.g. "Molten Maraging Steel 300").
local HIST_LABEL_MAX = 40
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
    crafting     = {},  -- nameLabelKey -> true for items on busy CPUs this cycle
    availableCpus = nil, -- free (non-busy) crafting CPUs this cycle; nil = unknown (getCpus failed)
    rrIdx        = 0,    -- round-robin rotation offset into stockedList, advances each cycle
}

local _patsByKey    = {}  -- itemKey -> craftable object cache
local _pendingJobs  = {}  -- itemKey -> {job, requestedAt, amount}
                          -- cleared when job finishes, cancels, or times out
local _epochOffset  = nil -- realUnixTime - computer.uptime() after NTP sync

-- Network fluids, rebuilt each stock cycle (and on pattern refresh). Used to
-- decide whether a stock entry is a fluid so its amounts render/parse in
-- L/KL/ML instead of a raw mB integer. AE2FC "drop" items still count via
-- ui.isDrop; these sets cover real fluids (Drilling Fluid, molten metals, …).
local _fluidNames   = {}  -- fluid name  -> true
local _fluidLabels  = {}  -- fluid label -> true

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

-- Key format: "<name>:<damage>\x1F<label>"
-- ASCII Unit Separator (\x1F) is unlikely to appear in any item name or label.
-- The label is included because AE2FC drops (and similarly NBT-tagged items)
-- share the same name+damage and can only be distinguished by their label.
local KEY_SEP = "\x1F"

local function itemKey(name, damage, label)
    return tostring(name) .. ":" .. tostring(damage or 0) .. KEY_SEP .. tostring(label or "")
end

-- Returns (name, damage, label). Tolerates legacy keys (no separator) by
-- treating the whole key as name:damage and returning label = "".
local function parseKey(key)
    local sepIdx = key:find(KEY_SEP, 1, true)
    local dataPart, label
    if sepIdx then
        dataPart = key:sub(1, sepIdx - 1)
        label    = key:sub(sepIdx + 1)
    else
        dataPart = key
        label    = ""
    end
    local lastColon
    for i = #dataPart, 1, -1 do
        if dataPart:sub(i, i) == ":" then lastColon = i; break end
    end
    if lastColon then
        return dataPart:sub(1, lastColon - 1), tonumber(dataPart:sub(lastColon + 1)) or 0, label
    end
    return dataPart, 0, label
end

-- Key by name+label only (ignores damage). This is the reliable common
-- denominator for matching a stocked item to network items and to the
-- items reported by busy crafting CPUs (this fork's craftable/CPU stacks
-- carry no dependable damage).
local function nameLabelKey(name, label)
    return tostring(name) .. KEY_SEP .. tostring(label or "")
end

-- True when a stock entry's amount should render/parse as a fluid volume
-- (L/KL/ML) rather than a raw integer: AE2FC "drop" items, or anything whose
-- name/label matches a fluid currently known to the network (see _fluidNames).
local function isFluidAmount(label, name)
    if ui.isDrop(label or "") then return true end
    if name  and _fluidNames[name]   then return true end
    if label and _fluidLabels[label] then return true end
    return false
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
        label  = unicode.sub(tostring(label), 1, HIST_LABEL_MAX),
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

-- Upgrade legacy `name:damage` keys in stockList to the new
-- `name:damage<SEP>label` format. Called after refreshPatterns so we can
-- match each legacy entry to a real pattern (by name+damage+label) and
-- adopt that pattern's new key. Without this, items added before the
-- label-aware format would silently fail to match any craftable.
local function migrateStockListKeys()
    local changed = false
    local newList = {}
    for oldKey, entry in pairs(M.config.stockList) do
        if oldKey:find(KEY_SEP, 1, true) then
            newList[oldKey] = entry  -- already new format
        else
            -- Reconstruct the legacy name:damage so we can match patterns.
            -- The legacy parseKey returned (name, damage); under the new
            -- parseKey, label is "" for legacy keys.
            local legacyName, legacyDmg = parseKey(oldKey)
            local newKey = nil
            for _, p in ipairs(state.patterns) do
                local pname, pdmg, plabel = parseKey(p.key)
                if pname == legacyName and pdmg == legacyDmg and plabel == (entry.label or "") then
                    newKey = p.key
                    break
                end
            end
            if newKey then
                newList[newKey] = entry
                changed = true
            else
                -- No pattern match (item may not be craftable anymore).
                -- Keep entry under a synthesized new-format key so it
                -- isn't lost, and the user can decide what to do.
                newList[itemKey(legacyName, legacyDmg, entry.label or "")] = entry
                changed = true
            end
        end
    end
    if changed then
        M.config.stockList = newList
        pcall(saveMyConfig)
    end
end

local function rebuildStockedList()
    state.stockedList = {}
    for key, entry in pairs(M.config.stockList) do
        table.insert(state.stockedList, {
            key      = key,
            label    = entry.label or key,
            level    = entry.level or 0,
            perCycle = entry.perCycle or 0,
            featured = entry.featured or false,
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
    -- The GTNH 2.9.x AE2 fork returns each craftable as an OC callback object
    -- (NetworkControl$Craftable) whose stack is fetched via getStack(). Older
    -- AE2 OC integrations used getItemStack(). Try both.
    local ok, stack = pcall(function() return c.getStack() end)
    if not (ok and type(stack) == "table" and stack.label) then
        ok, stack = pcall(function() return c.getItemStack() end)
    end
    if ok and type(stack) == "table" and stack.label then
        -- Craftable stacks in this fork carry no `damage` field (only `name`,
        -- `id`, `label`, `size`). `id` is an OC-internal global id, NOT the
        -- item metadata, so we do not use it. Matching is done by name+label
        -- (see checkAndStock), so a missing damage is harmless; default to 0.
        return stack.label, stack.name, stack.damage or 0
    end
    -- Fallback: direct string fields (plain table or proxy variants).
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
                local k = itemKey(name or "unknown", damage or 0, label)
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
    -- Upgrade legacy stockList keys to the new label-aware format whenever
    -- patterns are (re)loaded. Cheap no-op if already migrated.
    pcall(migrateStockListKeys)
    pcall(rebuildStockedList)
    -- Populate the fluid identity sets so the editor pretty-prints fluid
    -- volumes even before the first stock cycle runs (e.g. opening the editor
    -- straight from the pattern list on load).
    pcall(function()
        local fl = state.me.getFluidsInNetwork()
        if type(fl) ~= "table" then return end
        local names, labels = {}, {}
        for _, f in pairs(fl) do
            if type(f) == "table" then
                if f.name  then names[f.name]   = true end
                if f.label then labels[f.label] = true end
            end
        end
        _fluidNames, _fluidLabels = names, labels
    end)
    -- Free the old craftable userdata refs and any transient garbage
    gc()
end

-- Throttled variant for automatic recovery paths (stall/timeout).
-- Avoids burning memory rebuilding the entire pattern cache every cycle
-- when many items stall back-to-back. Home key still uses refreshPatterns
-- directly to bypass the throttle.
local function refreshPatternsThrottled()
    if computer.uptime() - _lastPatternRefresh < PATTERN_REFRESH_THROTTLE then return end
    pcall(refreshPatterns)
end

-- ── Pending craft tracking ───────────────────────────────────────────────────
--
-- Trust principle: if craftable.request() returned a job object, AE accepted
-- the submission. A craft can sit in AE's CPU queue for a long time (hours)
-- behind larger jobs; during that wait neither isLinked nor isComputing will
-- be true, but the job IS valid and re-submitting would just duplicate it.
--
-- Earlier revisions (preserved at git tag `stocker-stock-based-tracking`,
-- and at commit b4676f3 for the first state machine) timed out submissions
-- after 15 s and re-queued. That caused duplicate craft entries in AE for
-- any job waiting behind a larger one. This version removes that timeout
-- and waits indefinitely - only stall (after the job becomes active) and
-- the 2 h CRAFT_TIMEOUT backstop end a pending entry.
--
-- everSeenActive: latched true the first time we observe ANY positive
-- signal that AE has started processing the job. Used to:
--   - promote the history row from "queued" to "running"
--   - gate the stall detector so queued-but-waiting jobs do not stall
--   - enable release detection (was active, now both signals false)
--
-- Only positive signals are trusted. hasFailed() is still ignored entirely.

local CANCEL_COOLDOWN = 300        -- seconds after a user-cancel before retry
local FAILED_COOLDOWN = 300        -- seconds after AE silently dropped a craft

local _cancelCooldown = {}         -- key -> uptime to retry after user cancel
local _failedCooldown = {}         -- key -> uptime to retry after silent failure

-- Coarse per-item state for dashboard display (stock_dashboard module):
--   "ok"      - at/above target, nothing pending
--   "active"  - below target, a craft is queued or running
--   "problem" - below target, in cooldown after a recent cancel/silent failure
--   "idle"    - below target, no pending job and no recent failure
-- Reuses the same tracking tables processItem() already maintains, so no
-- extra bookkeeping is needed.
local function getItemState(key, entry, current)
    if current >= (entry.level or 0) then return "ok" end
    if _pendingJobs[key] then return "active" end
    local now = computer.uptime()
    if (_cancelCooldown[key] and now < _cancelCooldown[key])
    or (_failedCooldown[key] and now < _failedCooldown[key]) then
        return "problem"
    end
    return "idle"
end

-- Public accessor for the stock_dashboard module (Stock Maintainer system):
-- one row per item/fluid the user marked "featured" ([F] in the STOCKED
-- list), with current stock, target level, and coarse state for the status
-- square.
function M.getFeaturedStock()
    local result = {}
    for key, entry in pairs(M.config.stockList) do
        if entry.featured then
            local current = state.inStock[key] or 0
            local level   = entry.level or 0
            local name    = parseKey(key)
            table.insert(result, {
                key     = key,
                label   = entry.label or key,
                current = current,
                level   = level,
                percent = level > 0 and math.min(1, current / level) or 0,
                isFluid = isFluidAmount(entry.label, name),
                state   = getItemState(key, entry, current),
            })
        end
    end
    table.sort(result, function(a, b) return a.label:lower() < b.label:lower() end)
    return result
end

-- evaluateJob returns one of:
--   nil          - still in flight, leave pending in place
--   "done"       - target reached, requested amount delivered, isDone(true),
--                  or AE released the job after delivering stock
--   "cancelled"  - user cancelled via the terminal (isCanceled(true))
--   "stalled"    - job became active but no stock movement for STALL_WINDOW
--   "timeout"    - absolute backstop CRAFT_TIMEOUT exceeded
--   "failed"     - job reported hasFailed() (e.g. "no link" / missing ingredients)
local function evaluateJob(pending, current, level)
    local now = computer.uptime()

    pending.initialStock = pending.initialStock or current
    pending.peakStock    = math.max(pending.peakStock or pending.initialStock, current)

    -- ── Completion signals (apply regardless of phase) ──────────────────────

    if current >= level then return "done" end

    -- We received the amount we requested - this craft is done even if the
    -- overall level isn't met yet (perCycle splits the deficit into chunks).
    if pending.peakStock >= (pending.initialStock or 0) + (pending.amount or 0) then
        return "done"
    end

    -- Trust isDone()/isCanceled() only when positive. hasFailed() is NOT
    -- trusted: in this AE2 fork it returns true transiently (reason "no link")
    -- while a job merely WAITS for a free crafting CPU, then the job goes on
    -- to craft successfully. Acting on it wrongly marks live crafts "failed"
    -- (observed: Titanium/Aluminium crafting on CPUs yet reported failed).
    -- Real, unfulfillable jobs are instead caught when AE cancels them
    -- (isCanceled) or by the stall/timeout backstops with no stock movement.
    if pending.job then
        local okD, done = pcall(function() return pending.job.isDone() end)
        if okD and done then return "done" end

        local okC, cancelled = pcall(function() return pending.job.isCanceled() end)
        if okC and cancelled then return "cancelled" end
    end

    -- ── Sample current AE state ─────────────────────────────────────────────
    -- This fork's job exposes isComputing() but NOT isLinked(). Latch
    -- everSeenActive while the job is computing so the "running" promotion and
    -- stall detector behave once AE starts working on it.
    local computingNow = nil
    if pending.job then
        local okC, computing = pcall(function() return pending.job.isComputing() end)
        if okC then
            computingNow = computing
            if computing then pending.everSeenActive = true end
        end
    end

    -- Stock movement bookkeeping. Any change also counts as proof AE is
    -- processing the job, so it latches everSeenActive.
    pending.lastSeenStock = pending.lastSeenStock or current
    if current ~= pending.lastSeenStock then
        pending.lastSeenStock  = current
        pending.lastProgressAt = now
        pending.everSeenActive = true
    end

    -- ── Release detection ───────────────────────────────────────────────────
    -- This fork exposes no isLinked(), and isComputing()==false is ambiguous
    -- (an actively-crafting job also reports false), so we cannot infer
    -- "released" from the signals alone. Terminal outcomes are instead covered
    -- by hasFailed()/isDone()/isCanceled() above and the stock-based completion
    -- checks (current >= level, peakStock reached). Stall and the absolute
    -- CRAFT_TIMEOUT remain the backstops below.

    -- ── Stall: only meaningful AFTER the job became active ─────────────────
    -- A job queued in AE behind a larger one may legitimately sit idle for
    -- hours. We do NOT stall during that wait; the absolute CRAFT_TIMEOUT
    -- is the only ceiling. Once the job becomes active, normal stall
    -- detection kicks in.
    if pending.everSeenActive and pending.lastProgressAt then
        if now - pending.lastProgressAt > STALL_WINDOW then
            return "stalled"
        end
    end

    if now - pending.requestedAt > CRAFT_TIMEOUT then
        return "timeout"
    end

    return nil
end

-- Process a single stocked item. Isolated from other items so a thrown
-- error here cannot block siblings. cpuBudget (optional) is a shared
-- {available = n} table tracking free crafting CPUs left this cycle; nil
-- means CPU count could not be determined this cycle (getCpus failed), in
-- which case the CPU gate is skipped entirely rather than blocking crafts.
local function processItem(key, entry, current, cpuBudget)
    if not (entry.level and entry.level > 0) then return end
    local now = computer.uptime()

    -- Resolve pending job if there is one
    if _pendingJobs[key] then
        local pending = _pendingJobs[key]
        -- If AE reports this item on a busy crafting CPU, it is genuinely
        -- being made — the reliable "running" signal for this fork (the job
        -- object has no isLinked() and hasFailed() is unreliable).
        local pname, _pd, plabel = parseKey(key)
        if state.crafting[nameLabelKey(pname, plabel)] then
            pending.everSeenActive = true
        end
        local s = evaluateJob(pending, current, entry.level)
        if s then
            -- Update the existing "queued" row in place so a single line
            -- transitions queued -> done/cancelled/failed/stalled. Fall
            -- back to a fresh entry if the original row was overwritten
            -- by the ring buffer.
            if not updateHistoryStatus(pending.historyId, s) then
                addHistory(entry.label or key, pending.amount, s)
            end
            _pendingJobs[key] = nil

            if s == "cancelled" then
                _cancelCooldown[key] = now + CANCEL_COOLDOWN
                return
            end

            if s == "failed" then
                -- AE released without delivering. Wait before retrying
                -- so we do not spam an unfulfillable pattern.
                _failedCooldown[key] = now + FAILED_COOLDOWN
                return
            end

            if s == "stalled" or s == "timeout" then
                -- Stale craftable reference is a common cause. Refresh
                -- patterns (throttled) so the next request uses a fresh object.
                refreshPatternsThrottled()
            end
            -- "stalled" / "timeout" fall through to the submission block.
        else
            -- Promote the row from "queued" to "running" the first time
            -- AE confirms the craft has started moving.
            if pending.everSeenActive and not pending.runningLogged then
                updateHistoryStatus(pending.historyId, "running")
                pending.runningLogged = true
            end
            return  -- still in flight
        end
    end

    if current >= entry.level then return end

    -- Cooldowns after user cancel or AE silent rejection.
    if _cancelCooldown[key] and now < _cancelCooldown[key] then return end
    if _failedCooldown[key] and now < _failedCooldown[key] then return end
    _cancelCooldown[key] = nil
    _failedCooldown[key] = nil

    -- CPU gate: only submit a new craft request if a crafting CPU is free.
    -- Skip otherwise and retry on the next check cycle rather than queuing
    -- a request AE has nowhere to run yet.
    if cpuBudget and cpuBudget.available ~= nil and cpuBudget.available <= 0 then
        return
    end

    local deficit = entry.level - current
    local amount  = (entry.perCycle and entry.perCycle > 0)
                    and math.min(deficit, entry.perCycle)
                    or  deficit
    local craftable = _patsByKey[key]
    if not craftable then
        addHistory(entry.label or key, amount, "no pattern")
        return
    end

    -- Submit the request. Try the prioritize-power signature first
    -- (proven on the user's AE2 build), then fall back to alternates.
    local ok, job = pcall(function() return craftable.request(amount, true, nil) end)
    if not ok or job == nil then
        ok, job = pcall(function() return craftable.request(amount, false) end)
    end
    if not ok or job == nil then
        ok, job = pcall(function() return craftable.request(amount) end)
    end
    -- Last resort: ME-level requestCrafting using the parsed key.
    if not ok or job == nil then
        local name, damage = parseKey(key)
        ok, job = pcall(function()
            return state.me.requestCrafting({name = name, damage = damage}, amount)
        end)
    end

    if ok and job ~= nil then
        if cpuBudget and cpuBudget.available ~= nil then
            cpuBudget.available = cpuBudget.available - 1
        end
        local hid = addHistory(entry.label or key, amount, "queued")
        _pendingJobs[key] = {
            job            = job,
            requestedAt    = now,
            amount         = amount,
            initialStock   = current,
            peakStock      = current,
            lastSeenStock  = current,
            lastProgressAt = nil,         -- only set once stock actually moves
            historyId      = hid,
            everSeenActive = false,
            runningLogged  = false,
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
            local name, damage, label = parseKey(key)
            -- Filter by NAME only. Keys built from craftables carry no real
            -- damage (the fork's getStack() omits it, so it defaults to 0),
            -- while network items report a real damage. Passing damage here
            -- would wrongly exclude the very items we are counting. Name
            -- narrows the query; label disambiguation happens below.
            local ok, result = pcall(function()
                return state.me.getItemsInNetwork({name = name})
            end)
            if not ok or type(result) ~= "table" then
                allOk = false
                break
            end
            -- ALWAYS filter by label in our own code: the AE2 filter may
            -- ignore unknown keys, so multiple NBT-variants (e.g., AE2FC
            -- drops) can still come back. Skip mismatches explicitly.
            local total = 0
            for _, item in pairs(result) do
                if type(item) == "table" and item.name == name then
                    if label == "" or item.label == label then
                        total = total + (item.size or 0)
                    end
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
        -- Match by NAME (not name:damage): craftable-derived keys have no
        -- reliable damage, so we group wanted items by name and disambiguate
        -- by label, exactly like the filtered path.
        local wantedByName = {}
        for key, _ in pairs(M.config.stockList) do
            local n, _d, l = parseKey(key)
            wantedByName[n] = wantedByName[n] or {}
            table.insert(wantedByName[n], { key = key, label = l })
        end
        local items = state.me.getItemsInNetwork() or {}
        for _, item in pairs(items) do
            if type(item) == "table" and item.name then
                local candidates = wantedByName[item.name]
                if candidates then
                    for _, cand in ipairs(candidates) do
                        if cand.label == "" or item.label == cand.label then
                            inStock[cand.key] = (inStock[cand.key] or 0) + (item.size or 0)
                        end
                    end
                end
            end
        end
        items = nil
    end

    -- Fluids live in a separate bucket: getFluidsInNetwork() returns entries
    -- with `name` (e.g. "molten.steel"), `label` ("Molten Steel"), and
    -- `amount` in mB. AE2FC fluids (Drilling Fluid, Distilled Water, molten
    -- metals, …) are NOT items, so the item scans above always report 0 for
    -- them — which made the limit check (current >= level) never trip and the
    -- stocker re-request every cycle. Merge fluid amounts in here. The list is
    -- small (~100 entries) so this bulk call is cheap, unlike getItemsInNetwork.
    local fluidByName, fluidByLabel = {}, {}
    local fNames, fLabels = {}, {}
    local okF, fluids = pcall(function() return state.me.getFluidsInNetwork() end)
    if okF and type(fluids) == "table" then
        for _, fl in pairs(fluids) do
            if type(fl) == "table" then
                local amt = fl.amount or fl.size or 0
                if fl.name  then fluidByName[fl.name]   = (fluidByName[fl.name]   or 0) + amt; fNames[fl.name]   = true end
                if fl.label then fluidByLabel[fl.label] = (fluidByLabel[fl.label] or 0) + amt; fLabels[fl.label] = true end
            end
        end
        -- Publish the fluid identity sets so the display/editor can pretty-print
        -- fluid volumes. Only overwrite on a good read, so a transient API blip
        -- doesn't wipe formatting mid-session.
        _fluidNames, _fluidLabels = fNames, fLabels
    end
    -- Only fall back to fluids when the item scan found nothing for this key,
    -- so a real item can never be double-counted against a like-named fluid.
    -- Match by fluid name first (unique, collision-free), then by label.
    for key, _ in pairs(M.config.stockList) do
        if (inStock[key] or 0) == 0 then
            local name, _d, label = parseKey(key)
            local famt = fluidByName[name]
            if famt == nil and label ~= "" then famt = fluidByLabel[label] end
            if famt ~= nil then inStock[key] = famt end
        end
    end
    fluids = nil

    state.inStock = inStock

    -- Build the set of items currently being crafted on busy CPUs, so pending
    -- items can be marked "running" accurately. finalOutput() returns nil in
    -- this fork, so we scan each busy CPU's activeItems()+pendingItems() (the
    -- things being or about to be crafted) keyed by name+label. storedItems()
    -- are inputs, not outputs, so we skip them. getCpus is best-effort: any
    -- failure just yields an empty set (items fall back to stock-based state).
    local crafting = {}
    -- Also count free (non-busy) CPUs here so processItem can gate new craft
    -- submissions on actual availability instead of queuing blind.
    local totalCpus, busyCpus = 0, 0
    local okCpu, cpus = pcall(function() return state.me.getCpus() end)
    if okCpu and type(cpus) == "table" then
        for _, e in pairs(cpus) do
            if type(e) == "table" then
                totalCpus = totalCpus + 1
                if e.busy then busyCpus = busyCpus + 1 end
                if e.busy and e.cpu then
                    for _, method in ipairs({ "activeItems", "pendingItems" }) do
                        local okI, items = pcall(function() return e.cpu[method]() end)
                        if okI and type(items) == "table" then
                            for _, it in pairs(items) do
                                if type(it) == "table" and it.name then
                                    crafting[nameLabelKey(it.name, it.label)] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    state.crafting = crafting
    -- nil (unknown) when getCpus() itself failed, so the CPU gate in
    -- processItem is skipped rather than blocking every craft forever.
    state.availableCpus = okCpu and (totalCpus - busyCpus) or nil

    local cpuBudget = { available = state.availableCpus }

    -- Item processing order: plain pairs() iteration by default (arbitrary
    -- but stable per table), or a rotating order when roundRobin is enabled
    -- so free CPUs (limited by cpuBudget above) get distributed to a
    -- different item first each cycle instead of always the same ones.
    local orderedKeys = nil
    if M.config.roundRobin then
        orderedKeys = {}
        for _, item in ipairs(state.stockedList) do
            orderedKeys[#orderedKeys + 1] = item.key
        end
        local n = #orderedKeys
        if n > 0 then
            state.rrIdx = state.rrIdx % n
            local rotated = {}
            for i = 1, n do
                rotated[i] = orderedKeys[((state.rrIdx + i - 1) % n) + 1]
            end
            orderedKeys = rotated
            state.rrIdx = state.rrIdx + 1
        end
    end

    -- Isolate each item: a thrown error processing one must not prevent
    -- the others from being processed in the same cycle.
    local function runItem(key, entry)
        local current = inStock[key] or 0
        local ok, err = pcall(processItem, key, entry, current, cpuBudget)
        if not ok then
            addHistory(entry.label or key, 0, "err")
            _pendingJobs[key] = nil  -- prevent permanent block on a bad job
        end
    end

    if orderedKeys then
        for _, key in ipairs(orderedKeys) do
            local entry = M.config.stockList[key]
            if entry then runItem(key, entry) end
        end
    else
        for key, entry in pairs(M.config.stockList) do
            runItem(key, entry)
        end
    end

    -- Reclaim per-cycle garbage (network snapshot, transient closures, etc.)
    gc()
end

-- ── Editor helpers ────────────────────────────────────────────────────────────

-- Format an mB integer back into a compact drop string for the editor buffer
-- (e.g., 2000 -> "2L", 10000000 -> "10KL"). For non-drop items, just stringify.
local function editorFormat(value, isDropItem)
    if isDropItem then return ui.formatDrop(value or 0) end
    return tostring(value or 0)
end

-- Parse the editor buffer back to an integer count. For drops, accepts unit
-- suffixes (mb/L/KL/ML). Returns 0 on unparseable input rather than nil so
-- the caller never has to error-handle.
local function editorParse(str, isDropItem)
    if isDropItem then
        return ui.parseDropAmount(str) or tonumber(str) or 0
    end
    return tonumber(str) or 0
end

local function openEditor(key, label)
    local existing = M.config.stockList[key] or {}
    local kname = select(1, parseKey(key))
    local isDropItem = isFluidAmount(label, kname)
    state.editorMode  = true
    state.editorKey   = key
    state.editorLabel = label or key
    state.editorIsDrop = isDropItem
    state.editorField = "level"
    state.editorLevel = existing.level or 0
    state.editorBuf   = editorFormat(existing.level or 0, isDropItem)
    state._editorPerCycle = editorFormat(existing.perCycle or 1, isDropItem)
end

local function closeEditor(save)
    if save and state.editorKey then
        local isDropItem = state.editorIsDrop
        local lvl = tonumber(state.editorLevel) or 0
        local pc  = editorParse(state._editorPerCycle or "1", isDropItem)
        if state.editorField == "level" then
            lvl = editorParse(state.editorBuf, isDropItem)
        else
            pc  = editorParse(state.editorBuf, isDropItem)
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
    state.editorIsDrop = nil
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
    -- Error sits in the free gap just above the footer separator. y+h is one
    -- past the last visible row, so an error there is drawn off-screen — which
    -- is why failures previously showed as "nothing happening".
    local ERR_ROW    = y + h - 3

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

    -- Round-robin toggle + free-CPU count, right-aligned in the STOCKED
    -- header. Drop the CPU count, then the whole indicator, on screens too
    -- narrow to fit it without overlapping the "STOCKED" label.
    local minInfoX = x + 1 + unicode.len("STOCKED") + 1
    local rrStr    = "RR:" .. (M.config.roundRobin and "ON" or "OFF")
    local cpuStr   = state.availableCpus and (" CPU:" .. state.availableCpus) or ""
    local infoStr  = rrStr .. cpuStr
    local infoX    = x + colAW - unicode.len(infoStr)
    if infoX < minInfoX then
        infoStr = rrStr
        infoX   = x + colAW - unicode.len(infoStr)
    end
    if infoX >= minInfoX then
        gpu.setForeground(M.config.roundRobin and C_POS or C_DIM)
        gpu.set(infoX, headerRow, infoStr)
    end

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
                    local star    = item.featured and "*" or " "
                    local marker  = star .. (isCursor and "\xE2\x96\xB6 " or "  ")  -- "▶ "
                    local pending = _pendingJobs[item.key]
                    local right
                    if pending then
                        -- "craft" once AE has it on a busy CPU, otherwise the
                        -- job is queued/waiting for a free CPU.
                        local pname, _pd, plabel = parseKey(item.key)
                        if state.crafting[nameLabelKey(pname, plabel)] then
                            right = "craft"
                        else
                            local age = math.floor(computer.uptime() - pending.requestedAt)
                            right = string.format("wait %ds", age)
                        end
                    else
                        local cur = state.inStock[item.key] or 0
                        local iname = select(1, parseKey(item.key))
                        if isFluidAmount(item.label, iname) then
                            right = ui.formatDrop(cur) .. "/" .. ui.formatDrop(item.level)
                        else
                            right = string.format("%d/%d", cur, item.level)
                        end
                    end
                    local lw   = pw - unicode.len(marker) - #right - 1
                    local lbl  = unicode.sub(item.label, 1, lw)
                    local line = marker .. lbl .. string.rep(" ", lw - unicode.len(lbl)) .. " " .. right
                    gpu.setForeground(pending and C_NEG or (isCursor and C_LABEL or C_VALUE))
                    gpu.set(px, r, line:sub(1, pw + (#marker - unicode.len(marker))))
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
        local lvlBuf
        if state.editorField == "level" then
            lvlBuf = state.editorBuf
        else
            lvlBuf = editorFormat(state.editorLevel, state.editorIsDrop)
        end
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
        "[Up/Down] Navigate  [Left/Right] Switch  [Enter] Edit  [F] Feature  [R] Round-robin  [Del] Clear pending  [Type] Search  [Esc] Clear  [Home] Refresh  [Q] Quit")

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
        local isDropItem = state.editorIsDrop
        -- Drop editor accepts digits, decimal point, and unit letters (m/b/l/k/M/B/L/K),
        -- plus 'M' for ML. Plain items accept only digits.
        local accept = false
        if char >= 48 and char <= 57 then              -- 0-9
            accept = true
        elseif isDropItem then
            if char == 46 then                          -- '.'
                accept = true
            elseif char == 77 or char == 109            -- 'M' / 'm'
                or char == 75 or char == 107            -- 'K' / 'k'
                or char == 76 or char == 108            -- 'L' / 'l'
                or char == 66 or char == 98 then        -- 'B' / 'b'
                accept = true
            end
        end
        local maxLen = isDropItem and 12 or 9

        if accept then
            if #state.editorBuf < maxLen then
                state.editorBuf = state.editorBuf .. string.char(char)
            end
        elseif code == keyboard.keys.back then
            state.editorBuf = state.editorBuf:sub(1, -2)
        elseif code == keyboard.keys.enter then
            if state.editorField == "level" then
                state.editorLevel = editorParse(state.editorBuf, isDropItem)
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
    elseif (char == 102 or char == 70) and state.activePanel == "stocked" then -- 'f'/'F'
        local item = state.stockedList[state.cursorStk]
        if item then
            local entry = M.config.stockList[item.key]
            if entry then
                entry.featured = not entry.featured
                saveMyConfig()
                rebuildStockedList()
            end
        end
    elseif (char == 114 or char == 82) and state.activePanel == "stocked" then -- 'r'/'R'
        M.config.roundRobin = not M.config.roundRobin
        saveMyConfig()
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
