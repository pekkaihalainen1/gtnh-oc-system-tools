-- Config persistence using OC serialization library
local serialization = require("serialization")
local io = require("io")

local config = {}

-- Deep-merge src into dst (dst wins on conflicts at leaf level)
local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- Load config from path, merging saved values over defaults.
-- Returns the merged table. Writes defaults to disk if file missing.
function config.load(path, defaults)
    local result = {}
    merge(result, defaults or {})

    local f = io.open(path, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local ok, saved = pcall(serialization.unserialize, raw)
        if ok and type(saved) == "table" then
            -- Saved values override defaults (shallow-merge per module key)
            for k, v in pairs(saved) do
                if type(v) == "table" and type(result[k]) == "table" then
                    merge(result[k], v)
                    -- also let saved values win
                    for sk, sv in pairs(v) do
                        result[k][sk] = sv
                    end
                else
                    result[k] = v
                end
            end
        end
    end

    return result
end

-- Save config table to path.
function config.save(path, data)
    local f, err = io.open(path, "w")
    if not f then
        return false, err
    end
    f:write(serialization.serialize(data))
    f:close()
    return true
end

return config
