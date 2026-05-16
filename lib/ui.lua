-- Shared GPU rendering utilities
local unicode = require("unicode")

local ui = {}

-- ── Basic helpers ─────────────────────────────────────────────────────────────

function ui.clearRegion(gpu, x, y, w, h)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(x, y, w, h, " ")
end

-- Write text centered horizontally at a given row within [x, x+w)
function ui.setCentered(gpu, x, y, w, text)
    local len = unicode.len(text)
    local tx = x + math.floor((w - len) / 2)
    gpu.set(tx, y, text)
end

-- ── Color helpers ─────────────────────────────────────────────────────────────

function ui.getEnergyColor(percent, low, high)
    if percent <= low then
        return 0xFF2222  -- red: critical
    elseif percent <= 0.5 then
        return 0xFFAA00  -- amber: low
    elseif percent <= high then
        return 0x00DD44  -- green: good
    else
        return 0x00FFFF  -- cyan: full
    end
end

-- ── Formatting helpers ────────────────────────────────────────────────────────

-- Compact EU value: "123 EU", "12.3 KEU", "123.4 MEU", "1.23 GEU"
function ui.formatEU(n)
    n = math.floor(n or 0)
    if n >= 1e9 then
        return string.format("%.2f GEU", n / 1e9)
    elseif n >= 1e6 then
        return string.format("%.1f MEU", n / 1e6)
    elseif n >= 1e3 then
        return string.format("%.1f KEU", n / 1e3)
    else
        return string.format("%d EU", n)
    end
end

-- Human-readable duration from seconds: "~2h 14m", "~45m 3s", "< 1s"
-- Returns "---" for nil, negative, or very large values.
function ui.formatTime(seconds)
    if not seconds or seconds < 0 or seconds ~= seconds then return "---" end
    if seconds > 99 * 3600 then return "> 99h" end
    if seconds < 1 then return "< 1s" end
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("~%dh %dm", h, m)
    elseif m > 0 then
        return string.format("~%dm %ds", m, s)
    else
        return string.format("~%ds", s)
    end
end

-- ── Bar helpers ───────────────────────────────────────────────────────────────

-- Horizontal progress bar (legacy, kept for potential reuse)
function ui.drawProgressBar(gpu, x, y, w, h, percent, fillColor)
    gpu.setBackground(0x000000)
    gpu.setForeground(0x00CCCC)
    gpu.fill(x, y, w, 1, "═")
    gpu.fill(x, y + h - 1, w, 1, "═")
    gpu.fill(x, y, 1, h, "║")
    gpu.fill(x + w - 1, y, 1, h, "║")
    gpu.set(x, y, "╔")
    gpu.set(x + w - 1, y, "╗")
    gpu.set(x, y + h - 1, "╚")
    gpu.set(x + w - 1, y + h - 1, "╝")

    local innerW = w - 2
    local innerH = h - 2
    if innerW <= 0 or innerH <= 0 then return end

    gpu.setBackground(0x0D0D1A)
    gpu.fill(x + 1, y + 1, innerW, innerH, " ")

    local filled = math.floor(innerW * math.max(0, math.min(1, percent)))
    if filled > 0 then
        gpu.setBackground(fillColor)
        gpu.fill(x + 1, y + 1, filled, innerH, " ")
    end
    gpu.setBackground(0x000000)
end

-- ── Tab bar ───────────────────────────────────────────────────────────────────

function ui.drawTabBar(gpu, screenW, modules, activeIdx)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, screenW, 1, " ")

    local x = 1
    for i, mod in ipairs(modules) do
        local label = " " .. mod.name .. " "
        local len = unicode.len(label)
        if i == activeIdx then
            gpu.setBackground(0x00AAAA)
            gpu.setForeground(0x000000)
        else
            gpu.setBackground(0x222233)
            gpu.setForeground(0x8888AA)
        end
        if x + len - 1 <= screenW then
            gpu.set(x, 1, label)
        end
        x = x + len + 1
    end

    if x <= screenW then
        gpu.setBackground(0x000000)
        gpu.setForeground(0x333355)
        gpu.fill(x, 1, screenW - x + 1, 1, "─")
    end

    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
end

return ui
