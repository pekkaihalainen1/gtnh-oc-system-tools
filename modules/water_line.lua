-- Water Line Control module
-- Automates reagent dosing for the GT5 Water Purification Plant line
-- (Flocculation / pH Neutralization / ... purification units).
--
-- Ported from https://github.com/Navatusein/GTNH-OC-Water-Line-Control with
-- two fixes over the original:
--   1. A grade that gets auto-disabled (setWorkAllowed(false)) for running
--      out of a reagent now re-enables itself once the reagent is restocked,
--      instead of staying disabled forever.
--   2. GT sensor readings (pH value, chemical consumed this cycle, success
--      chance) are matched by searching every sensor line for a label
--      substring, instead of trusting a fixed line number/prefix. GTNH
--      2.9.x's getSensorInformation() layout does not match what the
--      original tool (written for 2.7/2.8) expects, which silently broke
--      T4 (nothing to dose because the pH line was never found). Press [D]
--      in this module to see the raw sensor lines live if a grade still
--      won't read correctly.
local component = require("component")
local computer   = require("computer")
local keyboard   = require("keyboard")
local unicode    = require("unicode")
local sides      = require("sides")
local ui         = require("lib/ui")

local M = {}
M.id   = "water_line"
M.name = "Water Line"

M.config = {
    t3 = {
        enable            = false,
        transposerAddress = "",  -- transposer that provides Polyaluminium Chloride
    },
    t4 = {
        enable                            = false,
        hydrochloricAcidTransposerAddress = "",  -- transposer that provides Hydrochloric Acid
        sodiumHydroxideTransposerAddress  = "",  -- transposer that provides Sodium Hydroxide Dust
    },
}

-- ── Colors (mirror power_control / dashboard palette) ────────────────────────

local C_TITLE = 0xFF00FF
local C_LABEL = 0x00A6FF
local C_VALUE = 0x00A6FF
local C_DIM   = 0x004477
local C_SEP   = 0x003355
local C_NEG   = 0xFF00FF
local C_WARN  = 0xFFAA00
local C_POS   = 0x00DD44

-- ── Log ring buffer ───────────────────────────────────────────────────────────

local LOG_MAX = 60
local log     = {}
local logHead, logCount = 1, 0
local debugView = false

local function addLog(text, level)
    log[logHead] = { when = os.date("%H:%M:%S"), text = text, level = level or "info" }
    logHead  = (logHead % LOG_MAX) + 1
    logCount = math.min(logCount + 1, LOG_MAX)
end

local function getLogOrdered()
    local result = {}
    if logCount == 0 then return result end
    local idx = (logHead - 2) % LOG_MAX + 1
    for i = logCount, 1, -1 do
        result[i] = log[idx]
        idx = (idx - 2) % LOG_MAX + 1
    end
    return result
end

-- Logs the same warning at most once per distinct message per grade, so a
-- persistent condition (e.g. "can't read pH") doesn't spam the feed every tick.
local _lastWarn = {}
local function warnOnce(grade, text)
    if _lastWarn[grade] == text then return end
    _lastWarn[grade] = text
    addLog(text, "warn")
end

-- ── Component discovery ───────────────────────────────────────────────────────

local function findGtMachine(name)
    for addr, ctype in component.list() do
        if ctype == "gt_machine" then
            local okP, proxy = pcall(component.proxy, addr)
            if okP and proxy then
                local okN, pname = pcall(proxy.getName)
                if okN and pname == name then return proxy end
            end
        end
    end
    return nil
end

local function findTransposer(address)
    if not address or address == "" then return nil end
    local okA, full = pcall(component.get, address, "transposer")
    if not okA or not full then return nil end
    local okP, proxy = pcall(component.proxy, full, "transposer")
    if not okP then return nil end
    return proxy
end

-- Scan every side/tank of a transposer for a fluid whose name contains
-- namePattern (case-insensitive). Re-run each time we need it (cheap: at
-- most 6 sides) rather than cached once at startup, so it also works when
-- the tank was empty at boot and only gets fluid later.
local function locateFluidSide(proxy, namePattern)
    if not proxy then return nil end
    for side = 0, 5 do
        local okC, tankCount = pcall(proxy.getTankCount, side)
        if okC and tankCount and tankCount > 0 then
            for tank = 1, tankCount do
                local okF, fluid = pcall(proxy.getFluidInTank, side, tank)
                if okF and type(fluid) == "table" and fluid.name
                        and fluid.name:lower():find(namePattern, 1, true) then
                    return side, tank, fluid
                end
            end
        end
    end
    return nil
end

-- Scan every side of a transposer for an item stack whose label contains
-- labelPattern (case-insensitive). Same "always re-scan" reasoning as above.
local function locateItemSide(proxy, labelPattern)
    if not proxy then return nil end
    local lp = labelPattern:lower()
    for side = 0, 5 do
        local okS, stacks = pcall(proxy.getAllStacks, side)
        if okS and stacks then
            local okA, all = pcall(stacks.getAll)
            if okA and all then
                for slot, item in pairs(all) do
                    if type(item) == "table" and item.label
                            and item.label:lower():find(lp, 1, true) then
                        return side, slot + 1, item
                    end
                end
            end
        end
    end
    return nil
end

-- ── Sensor parsing ────────────────────────────────────────────────────────────
-- Strip Minecraft "§x" color codes, then search EVERY line for a label
-- substring instead of trusting a fixed line index. This is what makes
-- reading survive a GT version bumping/reordering sensor lines.
--
-- On this GTNH build getSensorInformation() returns raw, UNTRANSLATED lang
-- keys joined with "\": e.g.
--   "GT5U.infodata.purification_unit_base.success_chance\100%"
-- instead of the localized "Success chance: 100%" the original tool (and a
-- plain text search) expects. Handle both: if a line contains "\", split it
-- into key + value parts and match patterns against the key; otherwise fall
-- back to the old "search the human-readable text" behavior in case a future
-- GTNH build (or a different multiblock) does have proper translations.

local function stripColor(s)
    return (s:gsub("§.", ""))
end

local function findSensorNumber(sensorLines, patterns)
    if type(sensorLines) ~= "table" then return nil end
    for _, line in ipairs(sensorLines) do
        local text = tostring(line)
        if text:find("\\", 1, true) then
            local parts = {}
            for part in text:gmatch("[^\\]+") do
                parts[#parts + 1] = part
            end
            local key = (parts[1] or ""):lower()
            for _, pat in ipairs(patterns) do
                if key:find(pat, 1, true) then
                    local raw = parts[#parts]
                    if raw then
                        local numStr = raw:gsub("%%", ""):gsub(",", ""):match("(%-?%d+%.?%d*)")
                        if numStr then return tonumber(numStr) end
                    end
                end
            end
        else
            local clean = stripColor(text):lower()
            for _, pat in ipairs(patterns) do
                if clean:find(pat, 1, true) then
                    local numStr = clean:gsub(",", ""):match("(%d+%.?%d*)")
                    if numStr then return tonumber(numStr) end
                end
            end
        end
    end
    return nil
end

-- ── Plant (Water Purification Plant) cycle watcher ────────────────────────────
-- Shared by every grade: a grade doses once per plant cycle, then waits for
-- the plant to start (or finish) its next one.

local plant = {
    controller       = nil,
    ready            = false,
    lastWorkProgress = 0,
    cycleEnded       = false,
}

local function plantTick()
    plant.cycleEnded = false
    if not plant.ready then
        plant.controller = findGtMachine("multimachine.purificationplant")
        plant.ready = plant.controller ~= nil
        if not plant.ready then return end
        addLog("[Plant] Water Purification Plant found", "info")
    end

    local okP, workProgress = pcall(plant.controller.getWorkProgress)
    local okH, hasWork      = pcall(plant.controller.hasWork)
    if not (okP and okH) then
        plant.ready = false
        warnOnce("plant", "[Plant] Lost connection to Water Purification Plant")
        return
    end

    if plant.lastWorkProgress > workProgress or (not hasWork and plant.lastWorkProgress ~= 0) then
        plant.cycleEnded = true
        plant.lastWorkProgress = 0
    end
    if hasWork then
        plant.lastWorkProgress = workProgress
    end
end

local function plantStatusText()
    if not plant.ready then return "Searching for Water Purification Plant...", C_DIM end
    local okH, hasWork = pcall(plant.controller.hasWork)
    if not okH then return "Error reading plant", C_NEG end
    if not hasWork then return "Idle (no cycle running)", C_DIM end
    local okA, progress = pcall(plant.controller.getWorkProgress)
    local okB, maxP      = pcall(plant.controller.getWorkMaxProgress)
    if okA and okB and maxP and maxP > 0 then
        return string.format("Cycle %d/%d", math.ceil(progress / 20), math.ceil(maxP / 20)), C_POS
    end
    return "Running", C_POS
end

-- ── T3: Flocculated Water (Grade 3) ───────────────────────────────────────────

local T3_REQUIRED = 900000  -- mB of Polyaluminium Chloride required per cycle

local t3 = {
    ready      = false,
    controller = nil,
    transposer = nil,
    state      = "idle",  -- idle | work | waitEnd
    sensor     = {},
}

local function t3Init()
    t3.controller = findGtMachine("multimachine.purificationunitflocculator")
    if M.config.t3.transposerAddress ~= "" then
        t3.transposer = findTransposer(M.config.t3.transposerAddress)
    end
    t3.ready = (t3.controller ~= nil) and (t3.transposer ~= nil)
end

local function t3DoWork()
    local currentCount = findSensorNumber(t3.sensor, { "flocculation.consumed", "polyaluminium chloride consumed" })
    if currentCount ~= nil and currentCount >= T3_REQUIRED then
        return
    end

    local side, tank = locateFluidSide(t3.transposer, "polyaluminiumchloride")
    if not side then
        warnOnce("t3", "[T3] Could not find Polyaluminium Chloride on the configured transposer")
        return
    end

    local fluidInTank = t3.transposer.getFluidInTank(side, tank)
    local countToAdd = T3_REQUIRED

    if fluidInTank.amount < T3_REQUIRED then
        pcall(t3.controller.setWorkAllowed, false)
        warnOnce("t3", "[T3] Not enough Polyaluminium Chloride for craft, pausing until restocked")
        countToAdd = fluidInTank.amount - (fluidInTank.amount % 100000)
    end

    if countToAdd > 0 then
        local okT, _, result = pcall(t3.transposer.transferFluid, side, sides.up, countToAdd, tank)
        if okT and result ~= countToAdd then
            addLog("[T3] Fluid transfer error", "warn")
        end
    end
end

-- Checks the multiblock's REAL isWorkAllowed() state rather than an in-memory
-- "we disabled it" flag: isWorkAllowed() is a property of the in-game block,
-- so a shortage-disable from a previous run of this program (or a previous,
-- buggier version of it) survives a restart even though our own local state
-- does not. Gating recovery on our own flag meant a disable from before this
-- program last started could never self-heal.
local function t3TryRecover()
    local okW, workAllowed = pcall(t3.controller.isWorkAllowed)
    if not okW or workAllowed ~= false then return end
    local side, tank = locateFluidSide(t3.transposer, "polyaluminiumchloride")
    if not side then return end
    local fluidInTank = t3.transposer.getFluidInTank(side, tank)
    if fluidInTank and fluidInTank.amount >= T3_REQUIRED then
        local okE = pcall(t3.controller.setWorkAllowed, true)
        if okE then
            _lastWarn.t3 = nil
            addLog("[T3] Polyaluminium Chloride restocked, controller re-enabled", "info")
        end
    end
end

local function t3Tick()
    if not M.config.t3.enable then return end

    if not t3.ready then
        t3Init()
        if not t3.ready then return end
        addLog("[T3] Flocculation Purification Unit found", "info")
    end

    local okS, sensor = pcall(t3.controller.getSensorInformation)
    t3.sensor = (okS and type(sensor) == "table") and sensor or {}

    local ok, err = pcall(function()
        if t3.state == "waitEnd" then
            if plant.cycleEnded then t3.state = "idle" end
            return
        end

        if t3.state == "idle" then
            t3TryRecover()

            local okH, hasWork = pcall(t3.controller.hasWork)
            if okH and hasWork then
                t3.state = "work"
                t3DoWork()
                t3.state = "waitEnd"
            end
        end
    end)

    if not ok then
        t3.ready = false
        warnOnce("t3err", "[T3] " .. tostring(err))
    end
end

local function t3StatusText()
    if not M.config.t3.enable then return "Disabled (see config.cfg)", C_DIM end
    if not t3.ready then
        if M.config.t3.transposerAddress == "" then
            return "Not configured: set t3.transposerAddress in config.cfg", C_NEG
        end
        return "Searching for hardware...", C_DIM
    end
    local okW, workAllowed = pcall(t3.controller.isWorkAllowed)
    if okW and workAllowed == false then return "Controller disabled (low stock)", C_NEG end
    local okH, hasWork = pcall(t3.controller.hasWork)
    if not (okH and hasWork) then return "Wait cycle", C_DIM end
    local successChance = findSensorNumber(t3.sensor, { "success_chance", "success chance" })
    local successStr = successChance and string.format("%d%%", successChance) or "N/A (press D)"
    return string.format("State: [%s]  Success: [%s]", t3.state, successStr), C_POS
end

-- ── T4: pH Neutralized Water (Grade 4) ────────────────────────────────────────

local t4 = {
    ready               = false,
    controller          = nil,
    acidTransposer      = nil,
    hydroxideTransposer = nil,
    state               = "idle",  -- idle | work | waitEnd
    sensor              = {},
}

local function t4Init()
    t4.controller = findGtMachine("multimachine.purificationunitphadjustment")
    if M.config.t4.hydrochloricAcidTransposerAddress ~= "" then
        t4.acidTransposer = findTransposer(M.config.t4.hydrochloricAcidTransposerAddress)
    end
    if M.config.t4.sodiumHydroxideTransposerAddress ~= "" then
        t4.hydroxideTransposer = findTransposer(M.config.t4.sodiumHydroxideTransposerAddress)
    end
    t4.ready = (t4.controller ~= nil) and (t4.acidTransposer ~= nil) and (t4.hydroxideTransposer ~= nil)
end

local function t4PutSodiumHydroxide(count)
    local side, slot = locateItemSide(t4.hydroxideTransposer, "sodium hydroxide dust")
    if not side then
        pcall(t4.controller.setWorkAllowed, false)
        warnOnce("t4hydrox", "[T4] Could not find Sodium Hydroxide Dust on the configured transposer")
        return
    end
    for i = 1, math.ceil(count / 64) do
        local n = math.min(64, count - 64 * (i - 1))
        local okT, result = pcall(t4.hydroxideTransposer.transferItem, side, sides.bottom, n)
        if not okT or result ~= n then
            pcall(t4.controller.setWorkAllowed, false)
            warnOnce("t4hydrox", "[T4] Not enough Sodium Hydroxide Dust for craft, pausing until restocked")
            break
        end
    end
end

local function t4PutHydrochloricAcid(count)
    local side, tank = locateFluidSide(t4.acidTransposer, "hydrochloricacid")
    if not side then
        pcall(t4.controller.setWorkAllowed, false)
        warnOnce("t4acid", "[T4] Could not find Hydrochloric Acid on the configured transposer")
        return
    end
    local amount = count * 10
    local okT, _, result = pcall(t4.acidTransposer.transferFluid, side, sides.bottom, amount, tank)
    if not okT or result ~= amount then
        pcall(t4.controller.setWorkAllowed, false)
        warnOnce("t4acid", "[T4] Not enough Hydrochloric Acid for craft, pausing until restocked")
    end
end

local function t4DoWork()
    local phValue = findSensorNumber(t4.sensor, { "ph_adjustment.ph", "ph value", "current ph", "ph level" })
    if phValue == nil then
        warnOnce("t4ph", "[T4] Could not read pH value from sensor info - press [D] to view raw sensor lines")
        return
    end

    local diffPh = 7 - phValue
    local count  = math.floor(math.abs(diffPh / 0.01))
    if count == 0 then return end

    if diffPh > 0 then
        t4PutSodiumHydroxide(count)
    else
        t4PutHydrochloricAcid(count)
    end
end

-- See t3TryRecover's comment: gate on the multiblock's real isWorkAllowed()
-- state, not an in-memory flag, so a shortage-disable from a previous run
-- can still self-heal after a restart.
local function t4TryRecover()
    local okW, workAllowed = pcall(t4.controller.isWorkAllowed)
    if not okW or workAllowed ~= false then return end
    local acidSide  = locateFluidSide(t4.acidTransposer, "hydrochloricacid")
    local hydroxSide = locateItemSide(t4.hydroxideTransposer, "sodium hydroxide dust")
    if acidSide and hydroxSide then
        local okE = pcall(t4.controller.setWorkAllowed, true)
        if okE then
            _lastWarn.t4acid   = nil
            _lastWarn.t4hydrox = nil
            addLog("[T4] Reagents restocked, controller re-enabled", "info")
        end
    end
end

local function t4Tick()
    if not M.config.t4.enable then return end

    if not t4.ready then
        t4Init()
        if not t4.ready then return end
        addLog("[T4] pH Neutralization Purification Unit found", "info")
    end

    local okS, sensor = pcall(t4.controller.getSensorInformation)
    t4.sensor = (okS and type(sensor) == "table") and sensor or {}

    local ok, err = pcall(function()
        if t4.state == "waitEnd" then
            if plant.cycleEnded then t4.state = "idle" end
            return
        end

        if t4.state == "idle" then
            t4TryRecover()

            local okH, hasWork = pcall(t4.controller.hasWork)
            if okH and hasWork then
                t4.state = "work"
                t4DoWork()
                t4.state = "waitEnd"
            end
        end
    end)

    if not ok then
        t4.ready = false
        warnOnce("t4err", "[T4] " .. tostring(err))
    end
end

local function t4StatusText()
    if not M.config.t4.enable then return "Disabled (see config.cfg)", C_DIM end
    if not t4.ready then
        if M.config.t4.hydrochloricAcidTransposerAddress == ""
                or M.config.t4.sodiumHydroxideTransposerAddress == "" then
            return "Not configured: set t4.*TransposerAddress in config.cfg", C_NEG
        end
        return "Searching for hardware...", C_DIM
    end
    local okW, workAllowed = pcall(t4.controller.isWorkAllowed)
    if okW and workAllowed == false then return "Controller disabled (low stock)", C_NEG end
    local okH, hasWork = pcall(t4.controller.hasWork)
    if not (okH and hasWork) then return "Wait cycle", C_DIM end
    local successChance = findSensorNumber(t4.sensor, { "success_chance", "success chance" })
    local successStr = successChance and string.format("%d%%", successChance) or "N/A (press D)"
    local phValue = findSensorNumber(t4.sensor, { "ph_adjustment.ph", "ph value", "current ph", "ph level" })
    local phStr = phValue and string.format("  pH: %.2f", phValue) or "  pH: ? (press D)"
    return string.format("State: [%s]  Success: [%s]%s", t4.state, successStr, phStr), C_POS
end

-- ── Module API ────────────────────────────────────────────────────────────────

function M.init(gpu, screenW, screenH)
    addLog("Water Line Control started", "info")
    return true  -- never fatal: a missing/misconfigured grade shows its own error
end

function M.start() end

function M.update()
    plantTick()
    t3Tick()
    t4Tick()
end

function M.stop()
    pcall(function()
        if t3.controller then t3.controller.setWorkAllowed(false) end
    end)
    pcall(function()
        if t4.controller then t4.controller.setWorkAllowed(false) end
    end)
end

-- ── drawUI ────────────────────────────────────────────────────────────────────

local function drawGradeRow(gpu, cx, row, w, label, statusText, statusColor)
    gpu.setForeground(C_LABEL)
    gpu.set(cx, row, label)
    gpu.setForeground(statusColor or C_VALUE)
    local vx = cx + unicode.len(label) + 1
    gpu.set(vx, row, unicode.sub(statusText, 1, math.max(0, w - (vx - cx) - 2)))
end

local function drawRawSensor(gpu, cx, row, endRow, label, sensorLines)
    if row > endRow then return row end
    gpu.setForeground(C_DIM)
    gpu.set(cx, row, label)
    row = row + 1
    if type(sensorLines) ~= "table" or #sensorLines == 0 then
        if row > endRow then return row end
        gpu.setForeground(C_DIM)
        gpu.set(cx + 2, row, "(no sensor data)")
        return row + 1
    end
    for i, line in ipairs(sensorLines) do
        if row > endRow then break end
        gpu.setForeground(C_DIM)
        gpu.set(cx + 2, row, string.format("[%d] %s", i, stripColor(tostring(line))))
        row = row + 1
    end
    return row
end

function M.drawUI(gpu, x, y, w, h)
    gpu.setBackground(0x000000)
    gpu.fill(x, y, w, h, " ")

    local cx  = x + 2
    local row = y + 1

    -- Title
    gpu.setForeground(C_TITLE)
    gpu.set(cx, row, "WATER LINE CONTROL")
    local ts = os.date("%H:%M:%S")
    gpu.setForeground(C_DIM)
    gpu.set(x + w - 1 - #ts, row, ts)
    gpu.setForeground(C_SEP)
    local sepStart = cx + 20
    local sepEnd   = x + w - 2 - #ts - 1
    if sepEnd > sepStart then
        gpu.fill(sepStart, row, sepEnd - sepStart, 1, "─")
    end

    row = row + 2
    drawGradeRow(gpu, cx, row, w, "PLANT              :", plantStatusText())
    row = row + 2
    drawGradeRow(gpu, cx, row, w, "T3  Grade 3 (Floc) :", t3StatusText())
    row = row + 1
    drawGradeRow(gpu, cx, row, w, "T4  Grade 4 (pH)   :", t4StatusText())

    row = row + 2
    gpu.setForeground(C_SEP)
    gpu.fill(cx, row, w - 4, 1, "─")
    row = row + 1

    local footRow  = y + h - 1
    local panelEnd = footRow - 2

    if debugView then
        gpu.setForeground(C_TITLE)
        gpu.set(cx, row, "RAW SENSOR LINES")
        row = row + 1
        if M.config.t3.enable then
            row = drawRawSensor(gpu, cx, row, panelEnd, "T3 (Flocculation Purification Unit):", t3.sensor)
        end
        if M.config.t4.enable then
            row = drawRawSensor(gpu, cx, row, panelEnd, "T4 (pH Neutralization Purification Unit):", t4.sensor)
        end
    else
        gpu.setForeground(C_TITLE)
        gpu.set(cx, row, "LOG")
        row = row + 1
        local entries  = getLogOrdered()
        local maxRows  = math.max(0, panelEnd - row + 1)
        local startIdx = math.max(1, #entries - maxRows + 1)
        for i = startIdx, #entries do
            local e = entries[i]
            local r = row + (i - startIdx)
            if r > panelEnd then break end
            gpu.setForeground(C_DIM)
            gpu.set(cx, r, e.when)
            local color = (e.level == "warn") and C_WARN or C_VALUE
            gpu.setForeground(color)
            gpu.set(cx + 9, r, unicode.sub(e.text, 1, w - 13))
        end
    end

    -- Footer
    gpu.setForeground(C_SEP)
    gpu.fill(cx, footRow - 1, w - 4, 1, "─")
    gpu.setForeground(C_DIM)
    gpu.set(cx, footRow,
        "[D] " .. (debugView and "Show log" or "Show raw sensor lines") .. "     [Q] Quit     [Tab] Switch tab")

    gpu.setForeground(C_VALUE)
    gpu.setBackground(0x000000)
end

function M.handleKey(char, code)
    if char == 100 or char == 68 then  -- 'd' / 'D'
        debugView = not debugView
    end
end

return M
