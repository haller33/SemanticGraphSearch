#!/usr/bin/env lua
-- semantic.lua - Unified fuzzy search pipeline with parametrized strategies
--
-- Features:
--   - SEARCH_MODE: "single", "dual_merge", or "prefix"
--   - NORMALIZE_ACCENTS: toggle accent normalization (á->a, etc.)
--   - MERGE_RESULTS: combine results from multiple searches
--   - PREFIX_SEARCH: find words that start with input (for prefix matching)
--   - DUAL_SEARCH_RESULTS_MULTIPLIER: get N*MAX_RESULTS before merging

local pprint = require('pprint')

local DICT_DB = "dicionariolatino.com/latin_portuguese.4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db"
local TRANSLATIONS_DB = "latin_to_narsese/narseses_latim_portugues.db"
local MAX_RESULTS = 5
local BAD_CONTENT_HASH = "32aaccb0c4597738cc2fca23b28557802587b9a9fa91d5c8c54beae8aedee5d9"
local EXCLUDE_BAD = true

-- Load database connections
local luasql = require("luasql.sqlite3")
local env = luasql.sqlite3()
local dict_db = env:connect(DICT_DB)
if not dict_db then error("Cannot connect to dictionary: " .. DICT_DB) end

local trans_db = env:connect(TRANSLATIONS_DB)

-- ========================================================================
-- SEARCH STRATEGY PARAMETERS
-- ========================================================================
-- Choose search mode: "single", "dual_merge", or "prefix"
local SEARCH_MODE = "dual_merge"

-- Normalize accents (á,à,ã,â -> a; é,è,ê -> e; etc.)
local NORMALIZE_ACCENTS = true

-- When using dual_merge, fetch this many results before merging
local DUAL_SEARCH_RESULTS_MULTIPLIER = 2

-- Enable prefix matching (search for words starting with input)
local ENABLE_PREFIX_SEARCH = true

-- Fuzzy score threshold: matches with score > this are rejected
local FUZZY_SCORE_THRESHOLD = 0.45

-- ========================================================================
-- HELPER FUNCTIONS: STRING NORMALIZATION
-- ========================================================================

-- Normalize Portuguese/Latin accents and special characters to ASCII
-- Maps: á,à,â,ã,ä -> a; é,è,ê,ë -> e; etc.
local function normalize_accents(s)
    if not s or s == "" then return "" end
    local accent_map = {
        -- Lowercase
        ['á']='a',['à']='a',['â']='a',['ã']='a',['ä']='a',
        ['é']='e',['è']='e',['ê']='e',['ë']='e',
        ['í']='i',['ì']='i',['î']='i',['ï']='i',
        ['ó']='o',['ò']='o',['ô']='o',['õ']='o',['ö']='o',
        ['ú']='u',['ù']='u',['û']='u',['ü']='u',
        ['ý']='y',['ÿ']='y',
        ['ç']='c',['ñ']='n',
        -- Uppercase
        ['Á']='a',['À']='a',['Â']='a',['Ã']='a',['Ä']='a',
        ['É']='e',['È']='e',['Ê']='e',['Ë']='e',
        ['Í']='i',['Ì']='i',['Î']='i',['Ï']='i',
        ['Ó']='o',['Ò']='o',['Ô']='o',['Õ']='o',['Ö']='o',
        ['Ú']='u',['Ù']='u',['Û']='u',['Ü']='u',
        ['Ý']='y',
        ['Ç']='c',['Ñ']='n',
    }
    return s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c) 
        return accent_map[c] or c 
    end)
end

-- Trim whitespace and strip punctuation from word edges
-- Returns: (original_cleaned, normalized_cleaned) if NORMALIZE_ACCENTS is true
--          otherwise: (original_cleaned, original_cleaned)
local function clean_word(word)
    if not word or word == "" then return "", "" end
    
    -- Trim whitespace from edges
    local trimmed = word:match("^%s*(.-)%s*$")
    
    -- Strip punctuation from start and end
    trimmed = trimmed:gsub("^[%p]+", ""):gsub("[%p]+$", "")
    
    -- Convert to lowercase for consistent searching
    local original = trimmed:lower()
    
    -- Apply accent normalization if enabled
    local normalized = original
    if NORMALIZE_ACCENTS then
        normalized = normalize_accents(original)
    end
    
    return original, normalized
end

-- ========================================================================
-- DATABASE FUNCTIONS
-- ========================================================================

-- Execute SQL query and return all rows
local function query_all(db_handle, sql)
    local cursor, err = db_handle:execute(sql)
    if not cursor then
        print("SQL error:", err or "unknown")
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

-- Execute SQL query and return first row or nil
local function query_one(db_handle, sql)
    local cursor, err = db_handle:execute(sql)
    if not cursor then
        return nil
    end
    local row = cursor:fetch({}, "a")
    cursor:close()
    return row
end

if not trans_db then
    print("Warning: translations database not found")
    print("Will use fallback NAL generation.")
    trans_db = nil
else
    -- Validate translations DB structure
    local tables = query_all(trans_db, "SELECT name FROM sqlite_master WHERE type='table'")
    print("Translations DB tables:")
    for _, t in ipairs(tables) do
        print(" - " .. t.name)
    end
    
    local has_translations = false
    for _, t in ipairs(tables) do
        if t.name == "translations" then
            has_translations = true
            break
        end
    end
    
    if not has_translations then
        print("Warning: 'translations' table not found. Using fallback.")
        trans_db:close()
        trans_db = nil
    else
    end
    
    if false then
        local cols = query_all(trans_db, "PRAGMA table_info(translations)")
        print("Columns in 'translations':")
        for _, c in ipairs(cols) do
            print(" - " .. c.name)
        end
    end
end

-- ========================================================================
-- SCORING FUNCTIONS
-- ========================================================================

-- Levenshtein distance: counts minimum edits to transform string s to t
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
            d[i][j] = math.min(
                d[i-1][j] + 1,      -- deletion
                d[i][j-1] + 1,      -- insertion
                d[i-1][j-1] + cost  -- substitution
            )
        end
    end
    return d[m][n]
end

-- Fuzzy score: normalized Levenshtein distance (0=perfect, 1=completely different)
-- Lower scores are better
local function fuzzy_score(word, target)
    local dist = levenshtein(word:lower(), target:lower())
    local max_len = math.max(#word, #target)
    if max_len == 0 then return 1 end
    return dist / max_len
end

-- Prefix score: how well does word start with target?
-- Returns 0 if perfect prefix match, higher values for mismatches
-- Used for prefix search strategy
local function prefix_score(word, target)
    word = word:lower()
    target = target:lower()
    
    if #target > #word then return 1 end  -- target longer than word
    
    local prefix = word:sub(1, #target)
    if prefix == target then
        return 0  -- Perfect prefix match
    end
    
    -- Measure prefix mismatch
    local dist = levenshtein(prefix, target)
    return dist / #target
end

-- ========================================================================
-- FUZZY SEARCH STRATEGIES
-- ========================================================================

-- Single fuzzy search: find matches in dictionary
-- Returns list of {word, definition, score}
local function fuzzy_search_single(input, max_results)
    if input == "" then return {} end
    
    local sql = "SELECT word, definition, content_hash FROM dictionary"
    if EXCLUDE_BAD then
        sql = sql .. " WHERE content_hash != '" .. BAD_CONTENT_HASH .. "'"
    end
    
    local rows = query_all(dict_db, sql)
    local results = {}
    
    for _, row in ipairs(rows) do
        local dict_word = row.word:lower()
        local dict_def = (row.definition or ""):lower()
        
        -- Score both word and definition, take minimum
        local score_word = fuzzy_score(dict_word, input)
        local score_def = fuzzy_score(dict_def, input)
        local best_score = math.min(score_word, score_def)
        
        if best_score < FUZZY_SCORE_THRESHOLD then
            table.insert(results, {
                word = row.word,
                definition = row.definition,
                score = best_score
            })
        end
    end
    
    -- Sort by score (lower = better)
    table.sort(results, function(a, b) return a.score < b.score end)
    
    -- Limit results
    if #results > max_results then
        for i = max_results + 1, #results do results[i] = nil end
    end
    
    return results
end

-- Dual fuzzy search: search with original AND normalized, merge best results
-- Returns list of {word, definition, score}
local function fuzzy_search_dual_merge(original, normalized, max_results)
    if original == "" then return {} end
    
    local search_limit = max_results * DUAL_SEARCH_RESULTS_MULTIPLIER
    
    -- Perform two independent searches
    local results_orig = fuzzy_search_single(original, search_limit)
    local results_norm = fuzzy_search_single(normalized, search_limit)
    
    -- Merge: keep best score for each word
    local merged_map = {}
    
    for _, r in ipairs(results_orig) do
        merged_map[r.word] = r
    end
    
    for _, r in ipairs(results_norm) do
        if merged_map[r.word] then
            -- Keep entry with lower (better) score
            if r.score < merged_map[r.word].score then
                merged_map[r.word] = r
            end
        else
            merged_map[r.word] = r
        end
    end
    
    -- Convert map back to sorted list
    local merged_list = {}
    for _, r in pairs(merged_map) do
        table.insert(merged_list, r)
    end
    
    table.sort(merged_list, function(a, b) return a.score < b.score end)
    
    -- Limit to MAX_RESULTS
    if #merged_list > max_results then
        for i = max_results + 1, #merged_list do merged_list[i] = nil end
    end
    
    return merged_list
end

-- Prefix search: find words starting with input, then fuzzy-score the prefixes
-- Useful for autocomplete-like behavior
-- Returns list of {word, definition, score}
local function fuzzy_search_prefix(input, max_results)
    if input == "" then return {} end
    
    local sql = "SELECT word, definition, content_hash FROM dictionary"
    if EXCLUDE_BAD then
        sql = sql .. " WHERE content_hash != '" .. BAD_CONTENT_HASH .. "'"
    end
    
    local rows = query_all(dict_db, sql)
    local results = {}
    
    for _, row in ipairs(rows) do
        local dict_word = row.word:lower()
        
        -- Use prefix score: words starting with input get better scores
        local score = prefix_score(dict_word, input)
        
        if score < FUZZY_SCORE_THRESHOLD then
            table.insert(results, {
                word = row.word,
                definition = row.definition,
                score = score
            })
        end
    end
    
    table.sort(results, function(a, b) return a.score < b.score end)
    
    if #results > max_results then
        for i = max_results + 1, #results do results[i] = nil end
    end
    
    return results
end

-- Main search dispatcher: chooses strategy based on SEARCH_MODE
-- Parameters:
--   original:  word with original accents (if any)
--   normalized: word with accents removed
--   max_results: maximum results to return
-- Returns: list of {word, definition, score}
local function fuzzy_search(original, normalized, max_results)
    if SEARCH_MODE == "single" then
        -- Simple single search using original form
        return fuzzy_search_single(original, max_results)
    
    elseif SEARCH_MODE == "dual_merge" then
        -- Two searches (original + normalized) with result merging
        return fuzzy_search_dual_merge(original, normalized, max_results)
    
    elseif SEARCH_MODE == "prefix" then
        -- Prefix-based search
        return fuzzy_search_prefix(original, max_results)
    
    else
        error("Unknown SEARCH_MODE: " .. SEARCH_MODE)
    end
end

-- ========================================================================
-- NARSESE RETRIEVAL AND GENERATION
-- ========================================================================

-- Retrieve pre-translated Narsese from translations database using word hash
-- Returns: Narsese string or nil if not found
local function get_narsese_for_word(word)
    if not trans_db then return nil end
    
    -- Compute SHA256 hash of word (same method as translator.modular.py)
    local function sha256(s)
        local handle = io.popen('echo -n "' .. s:gsub('"', '\\"') .. '" | sha256sum | cut -d" " -f1')
        local hash = handle:read("*a"):gsub("\n", "")
        handle:close()
        return hash
    end
    
    local word_hash = sha256(word)
    local sql = string.format("SELECT narsese_output FROM translations WHERE word_hash = '%s'", word_hash)
    local row = query_one(trans_db, sql)
    
    return row and row.narsese_output or nil
end

-- Clean Narsese: remove markdown backticks and format lines
-- Matches behavior of show_narseses.sh
local function clean_narsese(raw)
    if not raw then return nil end
    
    -- Remove markdown code fences
    local cleaned = raw:gsub("`", ""):gsub("```", "")
    
    -- Process lines: keep only those with Narsese brackets
    local lines = {}
    for line in cleaned:gmatch("[^\n]+") do
        if line:find("<") then
            -- Ensure line has Narsese structure
            line = "<" .. line .. ">."
            -- Fix doubled brackets
            line = line:gsub("<<", "<"):gsub(">>%.>%.", ">."):gsub(">%. %<", ">.\n<")
            table.insert(lines, line)
        end
    end
    
    return table.concat(lines, "\n")
end

-- Fallback Narsese: simple relation when no translation exists
local function fallback_narsese(word)
    return string.format("<%s --> latinWord>.", word)
end

-- ========================================================================
-- JSON CONVERSION AND GRAPH VISUALIZATION
-- ========================================================================

-- Convert Narsese to JSON using narsese2json.py
local function nal_to_json(nal_string)
    local safe = nal_string:gsub('"', '\\"')
    local cmd = string.format('echo "%s" | python3 narsese2json.py', safe)
    local handle = io.popen(cmd)
    if not handle then error("Failed to run narsese2json.py") end
    local out = handle:read("*a")
    handle:close()
    return out
end

-- Send JSON to graph visualizer via send2graph.py
local function json_to_graph(json_data)
    local safe_json = json_data:gsub("'", "'\\''")
    local cmd = string.format("echo '%s' | uv run --with requests python3 send2graph.py", safe_json)
    local handle = io.popen(cmd)
    if not handle then error("Failed to run send2graph.py") end
    local resp = handle:read("*a")
    handle:close()
    return resp
end

-- ========================================================================
-- MAIN PROCESSING PIPELINE
-- ========================================================================

local function process_phrase(phrase)
    print("\n========== PROCESSING PHRASE ==========")
    print("Original: " .. phrase)
    print("Search mode: " .. SEARCH_MODE)
    print("Normalize accents: " .. tostring(NORMALIZE_ACCENTS))
    print("========================================\n")
    
    -- Parse phrase into words
    local word_list = {}
    for w in phrase:gmatch("%S+") do
        local original, normalized = clean_word(w)
        if original ~= "" then
            table.insert(word_list, {
                original = original,
                normalized = normalized,
                raw = w
            })
        end
    end
    
    -- Process each word
    for _, word_info in ipairs(word_list) do
        print(string.format("\n--- WORD: '%s' ---", word_info.raw))
        
        if NORMALIZE_ACCENTS then
            print(string.format("  Original: '%s'", word_info.original))
            print(string.format("  Normalized: '%s'", word_info.normalized))
        end
        
        -- Perform fuzzy search
        local matches = fuzzy_search(
            word_info.original,
            word_info.normalized,
            MAX_RESULTS
        )
        
        if #matches == 0 then
            print("  Result: No matches found")
            goto next_word
        end
        
        print(string.format("  Found %d matches:", #matches))
        
        -- Process each match
        for idx, match in ipairs(matches) do
            print(string.format("\n  [%d/%d] Match: '%s' (score: %.4f)", 
                idx, #matches, match.word, match.score))
            
            -- Retrieve or generate Narsese
            local narsese_raw = get_narsese_for_word(match.word)
            local narsese = nil
            
            if narsese_raw then
                narsese = clean_narsese(narsese_raw)
                print("        Status: Using pre-translated Narsese")
            else
                narsese = fallback_narsese(match.word)
                print("        Status: Using fallback Narsese")
            end
            
            if not narsese or narsese == "" then
                print("        Error: Empty Narsese, skipping")
                goto next_match
            end
            
            print("        NAL:")
            for nal_line in narsese:gmatch("[^\n]+") do
                print("          " .. nal_line)
            end
            
            -- Convert to JSON
            local json = nal_to_json(narsese)
            if json and #json > 0 then
                print(string.format("        JSON preview: %s", json:sub(1, 150)))
                
                -- Send to graph visualizer
                local resp = json_to_graph(json)
                if resp and #resp > 0 then
                    print("        Graph response: " .. resp:sub(1, 100))
                else
                    print("        Graph response: (empty or no response)")
                end
            else
                print("        Error: narsese2json.py produced no output")
            end
            
            ::next_match::
        end
        
        ::next_word::
    end
    
    print("\n========== PROCESSING COMPLETE ==========\n")
end

-- ========================================================================
-- ENTRY POINT
-- ========================================================================

local phrase = arg[1] or "amor est vitae essentia"
process_phrase(phrase)

-- Cleanup
if dict_db then dict_db:close() end
if trans_db then trans_db:close() end
env:close()
