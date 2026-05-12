#!/usr/bin/env lua

-- filter_derived.lua - filter Derived lines by priority, frequency, and confidence
-- Usage: ./filter_derived.lua [--min-priority P] [--min-frequency F] [--min-confidence C]
-- Defaults: all thresholds = 0 (no filtering)

local min_priority = 0
local min_frequency = 0
local min_confidence = 0

-- Parse command line arguments
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

-- Helper: extract number using a pattern that matches digits, dot, e/E, plus, minus
-- The pattern works with Lua 5.1; hyphen is placed last to avoid range issues.
local function extract_number(line, pattern)
    local num_str = line:match(pattern)
    if num_str then
        return tonumber(num_str) or 0
    end
    return 0
end

-- Process stdin line by line
for line in io.lines() do
    if line:find("^Derived:") then
        local pri = extract_number(line, "Priority=([%d%.eE+%-]+)")
        local freq_str, conf_str = line:match("Truth: frequency=([%d%.eE+%-]+), confidence=([%d%.eE+%-]+)")
        local freq = freq_str and tonumber(freq_str) or 0
        local conf = conf_str and tonumber(conf_str) or 0

        if pri >= min_priority and freq >= min_frequency and conf >= min_confidence then
            print(line)
        end
    else
        print(line)
    end
end
