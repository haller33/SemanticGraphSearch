#!/usr/bin/env lua
-- filter_derived.lua - filter Derived lines by priority, frequency, confidence
-- Usage: ./filter_derived.lua [--min-priority P] [--min-frequency F] [--min-confidence C]

io.stdout:setvbuf('line')   -- force line buffering in pipes

local min_priority = 0
local min_frequency = 0
local min_confidence = 0

-- Parse arguments
local args = {...}
local i = 1
while i <= #args do
    local opt = args[i]
    if opt == "--min-priority" then
        min_priority = tonumber(args[i+1]) or 0
        i = i + 2
    elseif opt == "--min-frequency" then
        min_frequency = tonumber(args[i+1]) or 0
        i = i + 2
    elseif opt == "--min-confidence" then
        min_confidence = tonumber(args[i+1]) or 0
        i = i + 2
    else
        io.stderr:write("Unknown option: " .. opt .. "\n")
        os.exit(1)
    end
end

-- Robust number extraction: handles scientific notation, negative numbers, decimals
local function extract_number(line, key)
    local pattern = key .. "=([%d%.eE+%-]+)"
    local num_str = line:match(pattern)
    if num_str then
        local num = tonumber(num_str)
        if num then return num end
    end
    return 0
end

-- Process stdin line by line, never exit (even on error)
while true do
    local line = io.read()
    if not line then
        break   -- EOF (should not happen with tail -f, but handle gracefully)
    end

    -- Only filter lines that start with "Derived:"
    if line:find("^Derived:") then
        local pri = extract_number(line, "Priority")
        local freq_str, conf_str = line:match("Truth: frequency=([%d%.eE+%-]+), confidence=([%d%.eE+%-]+)")
        local freq = freq_str and tonumber(freq_str) or 0
        local conf = conf_str and tonumber(conf_str) or 0

        if pri >= min_priority and freq >= min_frequency and conf >= min_confidence then
            print(line)
        end
    else
        -- Pass through non-Derived lines unchanged (e.g., Input:, Selected:)
        print(line)
    end
    -- Flush explicitly (optional, setvbuf line already does it)
    io.stdout:flush()
end
