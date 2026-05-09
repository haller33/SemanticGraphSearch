#!/usr/bin/env lua
-- pipeline.lua - uses pre-translated Narsese from latin_to_narsese database

local DICT_DB = "dicionariolatino.com/latin_portuguese.4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db"
local TRANSLATIONS_DB = "latin_to_narsese/narseses_latim_portugues.db"
local MAX_RESULTS = 5
local BAD_CONTENT_HASH = "32aaccb0c4597738cc2fca23b28557802587b9a9fa91d5c8c54beae8aedee5d9"
local EXCLUDE_BAD = true

-- ----------------------------------------------------------------------
-- Helper: Execute SQL and return all rows (with error handling)
-- ----------------------------------------------------------------------
local function query_all(db_handle, sql)
    local cursor, err = db_handle:execute(sql)
    if not cursor then
        print("SQL error in query_all:", err or "unknown")
        return {}
    end
    local rows = {}
    local row = cursor:fetch({}, "a")
    while row do
        table.insert(rows, row)
        row = cursor:fetch({}, "a")
    end
    cursor:close()
    return rows
end

local function query_one(db_handle, sql)
    local cursor, err = db_handle:execute(sql)
    if not cursor then
        print("SQL error in query_one:", err or "unknown")
        return nil
    end
    local row = cursor:fetch({}, "a")
    cursor:close()
    return row
end

-- ----------------------------------------------------------------------
-- Load dictionary database (luasql.sqlite3)
-- ----------------------------------------------------------------------
local luasql = require("luasql.sqlite3")
local env = luasql.sqlite3()
local dict_db = env:connect(DICT_DB)
if not dict_db then error("Cannot connect to dictionary: " .. DICT_DB) end

local trans_db = env:connect(TRANSLATIONS_DB)
if not trans_db then
    print("Warning: translations database not found at " .. TRANSLATIONS_DB)
    print("Will use fallback NAL generation.")
    trans_db = nil
else
    -- Check if the translations table exists and list its columns (debug)
    local tables = query_all(trans_db, "SELECT name FROM sqlite_master WHERE type='table'")
    print("Tables in translations DB:")
    for _, t in ipairs(tables) do
        print(" - " .. t.name)
    end
    -- Check columns of the 'translations' table if it exists
    local has_translations = false
    for _, t in ipairs(tables) do
        if t.name == "translations" then
            has_translations = true
            break
        end
    end
    if not has_translations then
        print("Warning: 'translations' table not found. Will use fallback.")
        trans_db:close()
        trans_db = nil
    else
        -- Get column names for debugging
        local cols = query_all(trans_db, "PRAGMA table_info(translations)")
        print("Columns in 'translations':")
        for _, c in ipairs(cols) do
            print(" - " .. c.name)
        end
    end
end

-- ----------------------------------------------------------------------
-- Levenshtein distance (same as latin.lua)
-- ----------------------------------------------------------------------
local function levenshtein(s, t)
    local m, n = #s, #t
    if m == 0 then return n end
    if n == 0 then return m end
    local d = {}
    for i = 0, m do d[i] = { [0] = i } end
    for j = 0, n do d[0][j] = j end
    for i = 1, m do
        local si = s:sub(i, i)
        for j = 1, n do
            local cost = (si == t:sub(j, j)) and 0 or 1
            d[i][j] = math.min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + cost)
        end
    end
    return d[m][n]
end

local function fuzzy_score(word, target)
    local dist = levenshtein(word:lower(), target:lower())
    local max_len = math.max(#word, #target)
    if max_len == 0 then return 1 end
    return dist / max_len   -- lower = better
end

-- ----------------------------------------------------------------------
-- Fuzzy search in dictionary
-- ----------------------------------------------------------------------
local function fuzzy_search(input, max_results)
    local sql = "SELECT word, definition, content_hash FROM dictionary"
    if EXCLUDE_BAD then
        sql = sql .. " WHERE content_hash != '" .. BAD_CONTENT_HASH .. "'"
    end
    local rows = query_all(dict_db, sql)
    local results = {}
    for _, row in ipairs(rows) do
        local score_word = fuzzy_score(row.word, input)
        local score_def = fuzzy_score(row.definition or "", input)
        local best = math.min(score_word, score_def)
        if best < 0.45 then
            table.insert(results, { word = row.word, definition = row.definition, score = best })
        end
    end
    table.sort(results, function(a,b) return a.score < b.score end)
    if #results > max_results then
        for i = max_results + 1, #results do results[i] = nil end
    end
    return results
end

-- ----------------------------------------------------------------------
-- Retrieve pre‑translated Narsese from translations DB
-- ----------------------------------------------------------------------
local function get_narsese_for_word(word)
    if not trans_db then return nil end
    -- Compute SHA256 hash of the Latin word (same as translator.modular.py)
    local function sha256(s)
        local handle = io.popen('echo -n "' .. s:gsub('"', '\\"') .. '" | sha256sum | cut -d" " -f1')
        local hash = handle:read("*a"):gsub("\n", "")
        handle:close()
        return hash
    end
    local word_hash = sha256(word)
    local sql = string.format("SELECT narsese_output FROM translations WHERE word_hash = '%s'", word_hash)
    local row = query_one(trans_db, sql)
    if row and row.narsese_output then
        return row.narsese_output
    end
    return nil
end

-- ----------------------------------------------------------------------
-- Clean Narsese string exactly as show_narseses.sh does
-- ----------------------------------------------------------------------
local function clean_narsese(raw)
    if not raw then return nil end
    -- Remove backticks and triple backticks
    local cleaned = raw:gsub("`", ""):gsub("```", "")
    -- Keep only lines that contain '<' (simplified: we'll process whole string)
    local lines = {}
    for line in cleaned:gmatch("[^\n]+") do
        if line:find("<") then
            line = "<" .. line .. ">."
            line = line:gsub("<<", "<"):gsub(">>%.>%.", ">."):gsub(">%. %<", ">.\n<")
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

-- ----------------------------------------------------------------------
-- Fallback: generate simple Narsese (if no translation exists)
-- ----------------------------------------------------------------------
local function fallback_narsese(word)
    return string.format("<%s --> latinWord>.", word)
end

-- ----------------------------------------------------------------------
-- Call narsese2json.py
-- ----------------------------------------------------------------------
local function nal_to_json(nal_string)
    local safe = nal_string:gsub('"', '\\"')
    local cmd = string.format('echo "%s" | python3 narsese2json.py', safe)
    local handle = io.popen(cmd)
    if not handle then error("Failed to run narsese2json.py") end
    local out = handle:read("*a")
    handle:close()
    return out
end

-- ----------------------------------------------------------------------
-- Send JSON to graph visualizer using uv (provides requests)
-- ----------------------------------------------------------------------
local function json_to_graph(json_data)
    local safe_json = json_data:gsub("'", "'\\''")
    local cmd = string.format("echo '%s' | uv run --with requests python3 send2graph.py", safe_json)
    local handle = io.popen(cmd)
    if not handle then error("Failed to run send2graph.py") end
    local resp = handle:read("*a")
    handle:close()
    return resp
end

-- ----------------------------------------------------------------------
-- Main pipeline
-- ----------------------------------------------------------------------
local function process_phrase(phrase)
    print("Phrase: " .. phrase .. "\n")
    local words = {}
    for w in phrase:gmatch("%S+") do table.insert(words, w) end

    for _, raw_word in ipairs(words) do
        print("--- Word: " .. raw_word .. " ---")
        local matches = fuzzy_search(raw_word, MAX_RESULTS)
        if #matches == 0 then
            print("No Latin matches found.\n")
            goto continue
        end

        for _, match in ipairs(matches) do
            print(string.format("Match: %s (score %.3f)", match.word, match.score))
            local narsese_raw = get_narsese_for_word(match.word)
            local narsese = nil
            if narsese_raw then
                narsese = clean_narsese(narsese_raw)
                print("Using pre‑translated Narsese.")
            else
                narsese = fallback_narsese(match.word)
                print("No translation found, using fallback Narsese.")
            end
            if not narsese or narsese == "" then
                print("Empty Narsese, skipping.\n")
                goto next_match
            end
            print("NAL:\n" .. narsese)
            local json = nal_to_json(narsese)
            if json and #json > 0 then
                print("JSON (first 200 chars): " .. json:sub(1, 200))
                local resp = json_to_graph(json)
                print("Graph response: " .. (resp or "none") .. "\n")
            else
                print("narsese2json.py produced no output.\n")
            end
            ::next_match::
        end
        ::continue::
    end
end

-- ----------------------------------------------------------------------
-- Entry point
-- ----------------------------------------------------------------------
local phrase = arg[1] or "amor est vitae essentia"
process_phrase(phrase)

if dict_db then dict_db:close() end
if trans_db then trans_db:close() end
env:close()
