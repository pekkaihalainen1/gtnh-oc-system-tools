-- Shared GPU rendering utilities
local unicode = require("unicode")

local ui = {}

-- Fill a screen region with black background / white foreground
function ui.clearRegion(gpu, x, y, w, h)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(x, y, w, h, " ")
end

-- Draw a bordered progress bar. Interior fills from left by percent (0.0–1.0).
function ui.drawProgressBar(gpu, x, y, w, h, percent, fillColor)
    -- Border
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
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

    -- Clear interior
    gpu.setBackground(0x000000)
    gpu.fill(x + 1, y + 1, innerW, innerH, " ")

    -- Fill progress
    local filled = math.floor(innerW * math.max(0, math.min(1, percent)))
    if filled > 0 then
        gpu.setBackground(fillColor)
        gpu.fill(x + 1, y + 1, filled, innerH, " ")
    end

    gpu.setBackground(0x000000)
end

-- Return a color representing the energy level relative to thresholds
function ui.getEnergyColor(percent, low, high)
    if percent <= low then
        return 0xFF0000  -- red: critical
    elseif percent <= 0.5 then
        return 0xFFFF00  -- yellow: low
    elseif percent <= high then
        return 0x00FF00  -- green: good
    else
        return 0x00FFFF  -- cyan: full
    end
end

-- Draw a tab bar at row 1 across the full screen width.
-- modules: list of {name=...} tables; activeIdx: 1-based index of selected tab.
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
            gpu.setBackground(0x333333)
            gpu.setForeground(0xAAAAAA)
        end
        if x + len - 1 <= screenW then
            gpu.set(x, 1, label)
        end
        x = x + len + 1  -- 1-char gap between tabs
    end

    -- Fill remaining tab bar with separator line
    if x <= screenW then
        gpu.setBackground(0x000000)
        gpu.setForeground(0x333333)
        gpu.fill(x, 1, screenW - x + 1, 1, "─")
    end

    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
end

-- Write text centered horizontally at a given row within [x, x+w)
function ui.setCentered(gpu, x, y, w, text)
    local len = unicode.len(text)
    local tx = x + math.floor((w - len) / 2)
    gpu.set(tx, y, text)
end

return ui
