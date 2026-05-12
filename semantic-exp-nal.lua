#!/usr/bin/env lua
-- semantic-exp.lua – Latin dictionary searcher + Narsese fetching
-- Added --to-narsese flag to retrieve and clean Narsese from translations DB.

local DB_PATH = "dicionariolatino.com/latin_portuguese.4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db"
local TRANS_DB_PATH = "latin_to_narsese/narseses_latim_portugues.db"
local MAX_RESULTS = 20
local BAD_CONTENT_HASH = "32aaccb0c4597738cc2fca23b28557802587b9a9fa91d5c8c54beae8aedee5d9"
local exclude_bad = false
local output_hash = false
local C_LIB_PATH = "bin/fuzzy.so"
local to_narsese_mode = false
local verbose = false
local clean_narsese_flag = false
local use_c_fuzzy = false -- Toggle for C acceleration

local pprint = require('pprint')

-- ----------------------------------------------------------------------
-- Load luasql.sqlite3 (Nix environment)
-- ----------------------------------------------------------------------
local ok, luasql = pcall(require, "luasql.sqlite3")
if not ok then
    error("luasql.sqlite3 not found. Run inside nix-shell.")
end

local env = luasql.sqlite3()

-- Connect to dictionary database
local dict_db = env:connect(DB_PATH)
if not dict_db then error("Cannot connect to " .. DB_PATH) end

-- Connect to translations database (if needed later)
local trans_db = nil

-- ----------------------------------------------------------------------
-- Query helpers for dictionary DB
-- ----------------------------------------------------------------------
local function query_dict_rows(sql)
    local cursor = dict_db:execute(sql)
    local rows = {}
    local row = cursor:fetch({}, "a")
    while row do
        table.insert(rows, row)
        row = cursor:fetch({}, "a")
    end
    cursor:close()
    return rows
end

local function query_dict_one(sql)
    local cursor = dict_db:execute(sql)
    local row = cursor:fetch({}, "a")
    cursor:close()
    return row
end

-- ----------------------------------------------------------------------
-- Query helpers for translations DB
-- ----------------------------------------------------------------------
local function query_trans_one(sql)
    if not trans_db then return nil end
    local cursor = trans_db:execute(sql)
    local row = cursor:fetch({}, "a")
    cursor:close()
    return row
end

-- ----------------------------------------------------------------------
-- Helper: escape SQL string
-- ----------------------------------------------------------------------
local function escape(s)
    if not s then return "" end
    return s:gsub("'", "''")
end


-- ----------------------------------------------------------------------
-- Helper: add exclusion condition to WHERE clause
-- ----------------------------------------------------------------------
local function add_exclusion(where_clause)
    if exclude_bad then
        if where_clause and where_clause ~= "" then
            return where_clause .. " AND content_hash != '" .. BAD_CONTENT_HASH .. "'"
        else
            return "content_hash != '" .. BAD_CONTENT_HASH .. "'"
        end
    else
        return where_clause or ""
    end
end

-- ----------------------------------------------------------------------
-- OPTIONAL C LIBRARY ACCELERATION
-- ----------------------------------------------------------------------
local fuzzy_c = nil
local c_metadata_cache = {} -- Maps word -> {definition, hash}

local function load_fuzzy_c()
    local dir = C_LIB_PATH:match("(.*)/") or "."
    local orig_cpath = package.cpath
    package.cpath = dir .. "/?.so;" .. dir .. "/?.dll;" .. orig_cpath
    local ok, lib = pcall(require, "fuzzy")
    package.cpath = orig_cpath
    return ok and lib or nil
end

local function init_c_fuzzy()
    fuzzy_c = load_fuzzy_c()
    if not fuzzy_c then
        if verbose then io.stderr:write("Warning: C fuzzy library not found at " .. C_LIB_PATH .. "\n") end
        return false
    end

    local words = {}
    local sql = "SELECT word, definition, word_hash FROM dictionary"
    local cursor = dict_db:execute(sql)
    local row = cursor:fetch({}, "a")
    while row do
        table.insert(words, row.word)
        -- Store metadata to satisfy the original script's output contract
        c_metadata_cache[row.word] = { definition = row.definition, hash = row.word_hash }
        row = cursor:fetch({}, "a")
    end
    cursor:close()

    if fuzzy_c.init(words) then
        if verbose then print("C fuzzy search initialized with " .. #words .. " words") end
        return true
    end
    return false
end


-- ----------------------------------------------------------------------
-- Fuzzy matching (Levenshtein distance)
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
    return dist / max_len
end

-- ----------------------------------------------------------------------
-- Search functions (return tables with word, hash, def, score)
-- ----------------------------------------------------------------------
local function fuzzy_search(input, max_results)
    local results = {}

    -- BRANCH: C Library Acceleration
    if use_c_fuzzy or fuzzy_c then
        local c_results = fuzzy_c.search(input, max_results)
        for _, r in ipairs(c_results) do
            local word = r.word
            local max_len = math.max(#input, #word)
            local score = (max_len > 0) and (r.score / max_len) or 1
            
            if score < 0.45 then
                local meta = c_metadata_cache[word]
                table.insert(results, {
                    word = word,
                    def = meta and meta.definition or "",
                    score = score,
                    hash = meta and meta.hash or ""
                })
            end
        end
        return results
    end

    local rows = query_dict_rows("SELECT word, definition, content_hash, word_hash FROM dictionary")
    for _, row in ipairs(rows) do
        if not (exclude_bad and row.content_hash == BAD_CONTENT_HASH) then
            local score_word = fuzzy_score(row.word, input)
            local score_def  = fuzzy_score(row.definition or "", input)
            local best = math.min(score_word, score_def)
            if best < 0.45 then
                table.insert(results, {
                    word = row.word,
                    def = row.definition,
                    score = best,
                    hash = row.word_hash
                })
            end
        end
    end
    table.sort(results, function(a,b) return a.score < b.score end)
    if #results > max_results then
        for i = max_results + 1, #results do results[i] = nil end
    end
    return results
end

-- ----------------------------------------------------------------------
-- Trigram similarity (kept for completeness)
-- ----------------------------------------------------------------------
local trigram_cache = {}
local function get_trigrams(word)
    if trigram_cache[word] then return trigram_cache[word] end
    local trigrams = {}
    local padded = "$" .. word .. "$"
    for i = 1, #padded - 2 do
        local tri = padded:sub(i, i+2)
        trigrams[tri] = true
    end
    trigram_cache[word] = trigrams
    return trigrams
end

local function jaccard_similarity(set1, set2)
    local intersection = 0
    for k, _ in pairs(set1) do
        if set2[k] then intersection = intersection + 1 end
    end
    local size1 = 0; for _ in pairs(set1) do size1 = size1 + 1 end
    local size2 = 0; for _ in pairs(set2) do size2 = size2 + 1 end
    local union = size1 + size2 - intersection
    if union == 0 then return 0 end
    return intersection / union
end

local function trigram_search(input, max_results)
    local results = {}
    local query_trigrams = get_trigrams(input:lower())
    local rows = query_dict_rows("SELECT word, definition, content_hash, word_hash FROM dictionary")
    for _, row in ipairs(rows) do
        if not (exclude_bad and row.content_hash == BAD_CONTENT_HASH) then
            local word_trigrams = get_trigrams(row.word:lower())
            local sim = jaccard_similarity(query_trigrams, word_trigrams)
            if sim > 0.2 then
                table.insert(results, {
                    word = row.word,
                    def = row.definition,
                    score = sim,
                    hash = row.word_hash
                })
            end
        end
    end
    table.sort(results, function(a,b) return a.score > b.score end)
    if #results > max_results then
        for i = max_results + 1, #results do results[i] = nil end
    end
    return results
end

-- ----------------------------------------------------------------------
-- Output helpers (colours) – only used when not in to_narsese_mode
-- ----------------------------------------------------------------------
local function stdout_is_tty()
    local ok, f = pcall(io.open, "/dev/stdout", "r")
    if ok and f then f:close() return true end
    return false
end

local colours = stdout_is_tty() and {
    bold   = "\27[1m",
    green  = "\27[32m",
    yellow = "\27[33m",
    cyan   = "\27[36m",
    reset  = "\27[0m"
} or {
    bold = "", green = "", yellow = "", cyan = "", reset = ""
}

local function print_header(title)
    print(colours.bold .. colours.green .. title .. colours.reset)
end

local function print_result(word, definition, hash)
    if output_hash then
        print(hash or "(no hash)")
    else
        io.write(colours.cyan .. word .. colours.reset, ": ")
        if definition and #definition > 0 then
            print(definition:gsub("\n", " "))
        else
            print("(no definition)")
        end
    end
end

-- ----------------------------------------------------------------------
-- Narsese cleaning (replaces clean_narseses.sh)
-- ----------------------------------------------------------------------
local function clean_narsese(raw)
    if not raw then return nil end

    -- 1. Remove backticks and triple backticks (same as sed 's/`//g' and sed 's/```//g')
    local cleaned = raw:gsub("`", ""):gsub("```", "")

    -- 2. Split into lines (the shell script processes each line separately)
    local lines = {}
    for line in cleaned:gmatch("[^\n]+") do
        if line:match("%S") then   -- non‑empty line
            -- 3. sed 's/^/</g'  → add '<' at the beginning
            line = "<" .. line
            -- 4. sed 's/$/>./g' → add '>.' at the end
            line = line .. ">."
            -- 5. sed 's/</</g'   → replace '<<' with '<' (if any)
            line = line:gsub("<<", "<")
            -- 6. sed 's/>.>./>./g' – replace '>.>.' with '>.' *repeatedly* until no more
            while line:find(">%.") and line:find("%.>", line:find(">%.") + 1) do
                line = line:gsub(">%.>%.", ">.")
            end
            table.insert(lines, line)
        end
    end

    -- 7. Rejoin lines, then apply the final split: sed 's/>. </>.\n</g'
    local result = table.concat(lines, "\n")
    result = result:gsub(">%. %<", ">.\n<")

    return result
end

-- ----------------------------------------------------------------------
-- Fetch Narsese for a given word_hash from translations DB
-- ----------------------------------------------------------------------
local function fetch_narsese_for_hash(word_hash)
    if not trans_db then
        if verbose then io.stderr:write("Translations DB not connected\n") end
        return nil
    end
    local sql = string.format("SELECT narsese_output FROM translations WHERE word_hash = '%s'", word_hash)
    local row = query_trans_one(sql)
    if not row then
        if verbose then io.stderr:write("No row for hash: " .. word_hash .. "\n") end
        return nil
    end
    if not row.narsese_output then
        if verbose then io.stderr:write("Empty narsese_output for hash: " .. word_hash .. "\n") end
        return nil
    end
    return row.narsese_output
end

local function fetch_narsese_for_hash_old(word_hash)
    if not trans_db then return nil end
    local sql = string.format("SELECT narsese_output FROM translations WHERE word_hash = '%s'", word_hash)
    local row = query_trans_one(sql)
    if row and row.narsese_output then
        return row.narsese_output
    end
    return nil
end

-- ----------------------------------------------------------------------
-- Modified search functions with to_narsese_mode
-- ----------------------------------------------------------------------
local function prefix_search(prefix)
    
    if to_narsese_mode then
        local where = "word LIKE '" .. escape(prefix) .. "%'"
        where = add_exclusion(where)
        local sql = string.format("SELECT word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
        local rows = query_dict_rows(sql)
        for _, row in ipairs(rows) do
          local narsese_raw = fetch_narsese_for_hash(row.word_hash)
            if narsese_raw then
              if clean_narsese_flag then
                 local cleaned = clean_narsese(narsese_raw)
                 if cleaned then print(cleaned) end
              else
                print(narsese_raw)
              end
            end
        end
        return
    end

    -- Normal mode
    if output_hash then
        print_header("Hashes for words starting with '" .. prefix .. "':")
    else
        print_header("Words starting with '" .. prefix .. "':")
    end
    local where = "word LIKE '" .. escape(prefix) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local rows = query_dict_rows(sql)
    if #rows == 0 then
        print("(none)")
    else
        for _, row in ipairs(rows) do
            if output_hash then
                print(row.word_hash)
            else
                print(" • " .. row.word)
            end
        end
    end
end

local function definition_search(text)
    if to_narsese_mode then
        local where = "definition LIKE '%" .. escape(text) .. "%'"
        where = add_exclusion(where)
        local sql = string.format("SELECT word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
        local rows = query_dict_rows(sql)
        for _, row in ipairs(rows) do
            local narsese_raw = fetch_narsese_for_hash(row.word_hash)
            if narsese_raw then
              if clean_narsese_flag then
                 local cleaned = clean_narsese(narsese_raw)
                 if cleaned then print(cleaned) end
              else
                print(narsese_raw)
              end
            end
        end
        return
    end

    if output_hash then
        print_header("Hashes for definitions containing '" .. text .. "':")
    else
        print_header("Definitions containing '" .. text .. "':")
    end
    local where = "definition LIKE '%" .. escape(text) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, definition, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local rows = query_dict_rows(sql)
    if #rows == 0 then
        print("(none)")
    else
        for _, row in ipairs(rows) do
            print_result(row.word, row.definition, row.word_hash)
        end
    end
end

local function exact_search(query)
    if to_narsese_mode then
        local where = "word = '" .. escape(query) .. "'"
        where = add_exclusion(where)
        local sql = "SELECT word_hash FROM dictionary WHERE " .. where
        local row = query_dict_one(sql)
        if row then
            local narsese_raw = fetch_narsese_for_hash(row.word_hash)
            if narsese_raw then
              if clean_narsese_flag then
                 local cleaned = clean_narsese(narsese_raw)
                 if cleaned then print(cleaned) end
              else
                print(narsese_raw)
              end
            end
        end
        return
    end

    if output_hash then
        print_header("Hash for exact match '" .. query .. "':")
    else
        print_header("Exact match for '" .. query .. "':")
    end
    local sql = "SELECT word, definition, word_hash FROM dictionary WHERE word = '" .. escape(query) .. "'"
    local row = query_dict_one(sql)
    if row then
        print_result(row.word, row.definition, row.word_hash)
    else
        print("Not found.")
    end
end

local function fuzzy_and_prefix_wrapper(query, no_fuzzy)
    if to_narsese_mode then
        local hashes = {}
        -- Prefix
        local where = "word LIKE '" .. escape(query) .. "%'"
        where = add_exclusion(where)
        local sql = string.format("SELECT word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
        local rows = query_dict_rows(sql)
        for _, row in ipairs(rows) do
            hashes[row.word_hash] = true
        end
        -- Fuzzy (if not disabled)
        if not no_fuzzy then
            local fuzzy_results = fuzzy_search(query, MAX_RESULTS)
            for _, r in ipairs(fuzzy_results) do
                hashes[r.hash] = true
            end
        end
        for h, _ in pairs(hashes) do
            local narsese_raw = fetch_narsese_for_hash(h)
            if narsese_raw then
              if clean_narsese_flag then
                 local cleaned = clean_narsese(narsese_raw)
                 if cleaned then print(cleaned) end
              else
                print(narsese_raw)
              end
            end
        end
        return
    end

    -- Normal mode
    local where = "word LIKE '" .. escape(query) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local prefix_rows = query_dict_rows(sql)
    local prefix_list = {}
    for _, row in ipairs(prefix_rows) do
        table.insert(prefix_list, { word = row.word, hash = row.word_hash })
    end

    if #prefix_list > 0 then
        if output_hash then
            print_header("Hashes for prefix matches for '" .. query .. "':")
        else
            print_header("Prefix matches for '" .. query .. "':")
        end
        for _, item in ipairs(prefix_list) do
            if output_hash then
                print(item.hash)
            else
                print(" • " .. item.word)
            end
        end
        print()
    end

    if not no_fuzzy then
        local fuzzy_list = fuzzy_search(query, MAX_RESULTS)
        if #fuzzy_list > 0 then
            if output_hash then
                print_header("Hashes for fuzzy matches for '" .. query .. "':")
            else
                print_header("Fuzzy matches for '" .. query .. "':")
            end
            for _, r in ipairs(fuzzy_list) do
                print_result(r.word, r.def, r.hash)
            end
        elseif #prefix_list == 0 then
            print("Nothing found.")
        end
    elseif #prefix_list == 0 then
        print("Nothing found.")
    end
end

-- ----------------------------------------------------------------------
-- Raw HTML output (unchanged)
-- ----------------------------------------------------------------------
local function get_raw_html(word)
    local where = "word = '" .. escape(word) .. "'"
    where = add_exclusion(where)
    local sql = "SELECT raw_html FROM dictionary WHERE " .. where
    local row = query_dict_one(sql)
    if row and row.raw_html then
        print(row.raw_html)
    else
        io.stderr:write("No HTML content found for word: " .. word .. "\n")
        os.exit(1)
    end
end

local function handle_html(word)
    get_raw_html(word)
end

-- ----------------------------------------------------------------------
-- Helper for single hash lookup
-- ----------------------------------------------------------------------
local function hash_search(word)
    local sql = "SELECT word_hash FROM dictionary WHERE word = '" .. escape(word) .. "' LIMIT 1"
    local row = query_dict_one(sql)
    if row and row.word_hash then
        return row.word_hash
    end
    return nil
end

-- ----------------------------------------------------------------------
-- REPL (unchanged, but to_narsese_mode not available in REPL)
-- ----------------------------------------------------------------------
local function repl()
    print()
    print_header("Latin Dictionary REPL (universal)")
    print("Current result limit: " .. MAX_RESULTS)
    print("Exclude bad content_hash: " .. tostring(exclude_bad))
    print("Output hash mode: " .. tostring(output_hash))
    print("Commands:")
    print("  ?           – show this help")
    print("  q           – quit")
    print("  limit N     – set max results to N (e.g. limit 5)")
    print("  bad         – toggle exclusion of the known bad content_hash")
    print("  show-hash   – toggle output hash mode (show word_hash instead of word/def)")
    print("  p:WORD      – prefix search (word completion)")
    print("  f:WORD      – fuzzy search (typo‑tolerant, Levenshtein)")
    print("  t:WORD      – trigram similarity search (Jaccard index)")
    print("  d:TEXT      – search inside definitions")
    print("  h:WORD      – output raw HTML (for piping to your dumper)")
    print("  hash:WORD   – output the word_hash for the exact word")
    print("  WORD        – exact + prefix + fuzzy (combined)")
    print()
    io.write(colours.green .. "> " .. colours.reset)
    io.flush()

    for line in io.lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" then
            -- skip
        elseif line == "q" or line == "quit" or line == "exit" then
            break
        elseif line == "?" then
            print("Commands: ?, q, limit N, bad, show-hash, p:WORD, f:WORD, t:WORD, d:TEXT, h:WORD, hash:WORD, WORD")
        elseif line:sub(1,5) == "limit" then
            local n = tonumber(line:match("limit%s+(%d+)"))
            if n and n > 0 then
                MAX_RESULTS = n
                print("Result limit set to " .. MAX_RESULTS)
            else
                print("Invalid limit. Use: limit N (positive integer)")
            end
        elseif line == "bad" then
            exclude_bad = not exclude_bad
            print("Exclude bad content_hash: " .. tostring(exclude_bad))
        elseif line == "show-hash" then
            output_hash = not output_hash
            print("Output hash mode: " .. tostring(output_hash))
        elseif line:sub(1,2) == "p:" then
            prefix_search(line:sub(3))
        elseif line:sub(1,2) == "f:" then
            local fuzzy_results = fuzzy_search(line:sub(3), MAX_RESULTS)
            if output_hash then
                print_header("Hashes for fuzzy matches for '" .. line:sub(3) .. "':")
            else
                print_header("Fuzzy matches for '" .. line:sub(3) .. "':")
            end
            for _, r in ipairs(fuzzy_results) do
                print_result(r.word, r.def, r.hash)
            end
            if #fuzzy_results == 0 then print("(none)") end
        elseif line:sub(1,2) == "t:" then
            local trigram_results = trigram_search(line:sub(3), MAX_RESULTS)
            if output_hash then
                print_header("Hashes for trigram matches for '" .. line:sub(3) .. "':")
            else
                print_header("Trigram matches for '" .. line:sub(3) .. "':")
            end
            for _, r in ipairs(trigram_results) do
                print_result(r.word, r.def, r.hash)
            end
            if #trigram_results == 0 then print("(none)") end
        elseif line:sub(1,2) == "d:" then
            definition_search(line:sub(3))
        elseif line:sub(1,2) == "h:" then
            handle_html(line:sub(3))
        elseif line:sub(1,5) == "hash:" then
            local word = line:sub(6)
            local word_hash = hash_search(word)
            if word_hash then
                print(word_hash)
            else
                print("Word not found.")
            end
        else
            fuzzy_and_prefix_wrapper(line, false)
        end
        print()
        io.write(colours.green .. "> " .. colours.reset)
        io.flush()
    end
end

-- ----------------------------------------------------------------------
-- Parse command line (added --to-narsese)
-- ----------------------------------------------------------------------
local function show_usage()
    print([[
Usage:
  lua semantic-exp-nal.lua                      → interactive REPL
  lua semantic-exp-nal.lua --limit N "word"     → set limit to N for that search
  lua semantic-exp-nal.lua "word"               → exact + prefix + fuzzy (default)
  lua semantic-exp-nal.lua --exact "word"       → only exact match
  lua semantic-exp-nal.lua --no-fuzzy "word"    → exact + prefix (no fuzzy)
  lua semantic-exp-nal.lua --prefix "pref"      → list words starting with 'pref'
  lua semantic-exp-nal.lua --fuzzy "word"       → fuzzy search only (Levenshtein)
  lua semantic-exp-nal.lua --trigram "word"     → trigram similarity search (Jaccard)
  lua semantic-exp-nal.lua --def "text"         → search inside definitions
  lua semantic-exp-nal.lua --html "word"        → output raw HTML for that word
  lua semantic-exp-nal.lua --hash "word"        → output the word_hash for the exact word (single)
  lua semantic-exp-nal.lua --show-hash          → show word_hash instead of word/definition for any search
  lua semantic-exp-nal.lua --to-narsese         → fetch and output cleaned Narsese statements (for given search)
  lua semantic-exp-nal.lua --hash-file file     → output word_hashes for each word in file (one per line)
  lua semantic-exp-nal.lua --exclude-bad        → exclude entries with the problematic content_hash
  lua semantic-exp-nal.lua --clean_narsese        → exclude entries with the problematic content_hash
  lua semantic-exp-nal.lua --fuzzy-c          → fuzzy c library
]])
end

local function main(args)
    -- check that the dictionary table exists
    local row = query_dict_one("SELECT name FROM sqlite_master WHERE type='table' AND name='dictionary'")
    if not row then
        print("Error: 'dictionary' table not found.")
        os.exit(1)
    end

    local limit = MAX_RESULTS
    local no_fuzzy = false
    local exact_mode = false
    local new_args = {}
    local i = 1
    while i <= #args do
        if args[i] == "--verbose" then
            verbose = true
            i = i + 1
        elseif args[i] == "--limit" and i+1 <= #args then
            local n = tonumber(args[i+1])
            if n and n >= 0 then
                limit = n
            else
                print("Invalid --limit value. Using default " .. MAX_RESULTS)
            end
            i = i + 2
        elseif args[i] == "--fuzzy-c" or args[i] == "--lib-c" then
          use_c_fuzzy = true
          i = i + 1
        elseif args[i] == "--no-fuzzy" then
            no_fuzzy = true
            i = i + 1
        elseif args[i] == "--clean_narsese" then
            clean_narsese_flag = true
            i = i + 1
        elseif args[i] == "--exact" then
            exact_mode = true
            i = i + 1
        elseif args[i] == "--exclude-bad" then
            exclude_bad = true
            i = i + 1
        elseif args[i] == "--show-hash" then
            output_hash = true
            i = i + 1
        elseif args[i] == "--to-narsese" then
            to_narsese_mode = true
            output_hash = false
            if not trans_db then
                trans_db = env:connect(TRANS_DB_PATH)
                if not trans_db then
                    io.stderr:write("Error: Cannot open translations database at " .. TRANS_DB_PATH .. "\n")
                    os.exit(1)
                end
                local check = query_trans_one("SELECT name FROM sqlite_master WHERE type='table' AND name='translations'")
                if not check then
                    io.stderr:write("Error: 'translations' table not found in " .. TRANS_DB_PATH .. "\n")
                    os.exit(1)
                end
            end
            i = i + 1
        elseif args[i] == "--hash" and i+1 <= #args then
            local word = args[i+1]
            local word_hash = hash_search(word)
            if word_hash then
                print(word_hash)
            else
                print("Word not found.")
            end
            os.exit(0)
        elseif args[i] == "--hash-file" and i+1 <= #args then
            local filename = args[i+1]
            local file = io.open(filename, "r")
            if not file then
                print("Error: cannot open file " .. filename)
                os.exit(1)
            end
            for line in file:lines() do
                local word = line:match("^%s*(.-)%s*$")
                if word and word ~= "" then
                    local word_hash = hash_search(word)
                    if word_hash then
                        print(word_hash)
                    else
                        print("Word not found: " .. word)
                    end
                end
            end
            file:close()
            os.exit(0)
        else
            table.insert(new_args, args[i])
            i = i + 1
        end
    end
    MAX_RESULTS = limit

    if use_c_fuzzy then init_c_fuzzy() end
      
    if #new_args == 0 then
        repl()
    elseif new_args[1] == "--prefix" and #new_args >= 2 then
        prefix_search(new_args[2])
    elseif new_args[1] == "--fuzzy" and #new_args >= 2 then
        if to_narsese_mode then
            local fuzzy_results = fuzzy_search(new_args[2], MAX_RESULTS)
            for _, r in ipairs(fuzzy_results) do
                local narsese_raw = fetch_narsese_for_hash(r.hash)
                if narsese_raw then
                  if clean_narsese_flag then
                    local cleaned = clean_narsese(narsese_raw)
                    if cleaned then print(cleaned) end
                  else
                    print(narsese_raw)
                  end
                end
            end
        else
            local fuzzy_results = fuzzy_search(new_args[2], MAX_RESULTS)
            if output_hash then
                print_header("Hashes for fuzzy matches for '" .. new_args[2] .. "':")
            else
                print_header("Fuzzy matches for '" .. new_args[2] .. "':")
            end
            for _, r in ipairs(fuzzy_results) do
                print_result(r.word, r.def, r.hash)
            end
            if #fuzzy_results == 0 then print("(none)") end
        end
    elseif new_args[1] == "--trigram" and #new_args >= 2 then
        if to_narsese_mode then
            local trigram_results = trigram_search(new_args[2], MAX_RESULTS)
            for _, r in ipairs(trigram_results) do
                local narsese_raw = fetch_narsese_for_hash(r.hash)
                if narsese_raw then
                  if clean_narsese_flag then
                    local cleaned = clean_narsese(narsese_raw)
                    if cleaned then print(cleaned) end
                  else
                    print(narsese_raw)
                  end
                end
            end
        else
            local trigram_results = trigram_search(new_args[2], MAX_RESULTS)
            if output_hash then
                print_header("Hashes for trigram matches for '" .. new_args[2] .. "':")
            else
                print_header("Trigram matches for '" .. new_args[2] .. "':")
            end
            for _, r in ipairs(trigram_results) do
                print_result(r.word, r.def, r.hash)
            end
            if #trigram_results == 0 then print("(none)") end
        end
    elseif new_args[1] == "--def" and #new_args >= 2 then
        definition_search(new_args[2])
    elseif new_args[1] == "--html" and #new_args >= 2 then
        handle_html(new_args[2])
    elseif new_args[1] == "--help" or new_args[1] == "-h" then
        show_usage()
    else
        local query = new_args[1]
        if exact_mode then
            exact_search(query)
        else
            fuzzy_and_prefix_wrapper(query, no_fuzzy)
        end
    end
end

-- run
local args = {}
for i = 1, #arg do args[i] = arg[i] end
main(args)

-- close database connections
dict_db:close()
if trans_db then trans_db:close() end
env:close()
