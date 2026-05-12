#!/usr/bin/env lua
-- latin.lua – Universal Latin dictionary searcher
-- Works with luasql.sqlite3 (Nix) or native sqlite3 (Kindle)
-- Added --show-hash flag to output word_hash instead of word/definition.
-- All searches now also retrieve the word_hash column.

local DB_PATH = "dicionariolatino.com/latin_portuguese.4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db"
local MAX_RESULTS = 20
local BAD_CONTENT_HASH = "32aaccb0c4597738cc2fca23b28557802587b9a9fa91d5c8c54beae8aedee5d9"
local exclude_bad = false
local output_hash = false   -- NEW: if true, print hashes instead of words/definitions

-- ----------------------------------------------------------------------
-- Dynamic module loading and API abstraction
-- ----------------------------------------------------------------------
local db
local query_rows  -- function that takes SQL and returns a table of rows (each row is a table)
local query_one    -- function for single row (exact match / HTML)

-- Try luasql.sqlite3 first (Nix)
local ok, luasql = pcall(require, "luasql.sqlite3")
if ok then
    -- Use luasql.sqlite3
    local env = luasql.sqlite3()
    db = env:connect(DB_PATH)
    if not db then error("Cannot connect to " .. DB_PATH) end

    query_rows = function(sql)
        local cursor = db:execute(sql)
        local rows = {}
        local row = cursor:fetch({}, "a")
        while row do
            table.insert(rows, row)
            row = cursor:fetch({}, "a")
        end
        cursor:close()
        return rows
    end

    query_one = function(sql)
        local cursor = db:execute(sql)
        local row = cursor:fetch({}, "a")
        cursor:close()
        return row
    end
else
    -- Fall back to sqlite3 (Kindle)
    local sqlite3 = require("sqlite3")
    db = sqlite3.open(DB_PATH)
    if not db then error("Cannot open " .. DB_PATH) end

    query_rows = function(sql)
        local rows = {}
        for row in db:nrows(sql) do
            table.insert(rows, row)
        end
        return rows
    end

    query_one = function(sql)
        local stmt = db:prepare(sql)
        local row = nil
        if stmt:step() == sqlite3.ROW then
            row = {}
            for i = 0, stmt:column_count() - 1 do
                row[stmt:column_name(i)] = stmt:get_value(i)
            end
        end
        stmt:finalize()
        return row
    end
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

-- Modified: now selects word_hash as well
local function fuzzy_search(input, max_results)
    local results = {}
    local rows = query_rows("SELECT word, definition, content_hash, word_hash FROM dictionary")
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
                    hash = row.word_hash   -- NEW
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
-- Trigram similarity
-- ----------------------------------------------------------------------
local trigram_cache = {}

local function get_trigrams(word)
    if trigram_cache[word] then
        return trigram_cache[word]
    end
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
        if set2[k] then
            intersection = intersection + 1
        end
    end
    local size1 = 0; for _ in pairs(set1) do size1 = size1 + 1 end
    local size2 = 0; for _ in pairs(set2) do size2 = size2 + 1 end
    local union = size1 + size2 - intersection
    if union == 0 then return 0 end
    return intersection / union
end

-- Modified: now selects word_hash
local function trigram_search(input, max_results)
    local results = {}
    local query_trigrams = get_trigrams(input:lower())
    local rows = query_rows("SELECT word, definition, content_hash, word_hash FROM dictionary")
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
-- Output helpers (colours)
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

-- Modified: now prints hash if output_hash is true
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
-- Database query functions (using the abstraction)
-- ----------------------------------------------------------------------
-- Modified prefix_search to include word_hash
local function prefix_search(prefix)
    if output_hash then
        print_header("Hashes for words starting with '" .. prefix .. "':")
    else
        print_header("Words starting with '" .. prefix .. "':")
    end
    local where = "word LIKE '" .. escape(prefix) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local rows = query_rows(sql)
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

-- Modified definition_search to include word_hash
local function definition_search(text)
    if output_hash then
        print_header("Hashes for definitions containing '" .. text .. "':")
    else
        print_header("Definitions containing '" .. text .. "':")
    end
    local where = "definition LIKE '%" .. escape(text) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, definition, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local rows = query_rows(sql)
    if #rows == 0 then
        print("(none)")
    else
        for _, row in ipairs(rows) do
            print_result(row.word, row.definition, row.word_hash)
        end
    end
end

-- Modified exact_search to include word_hash
local function exact_search(query)
    if output_hash then
        print_header("Hash for exact match '" .. query .. "':")
    else
        print_header("Exact match for '" .. query .. "':")
    end
    local where = "word = '" .. escape(query) .. "'"
    where = add_exclusion(where)
    local sql = "SELECT word, definition, word_hash FROM dictionary WHERE " .. where
    local row = query_one(sql)
    if row then
        print_result(row.word, row.definition, row.word_hash)
    else
        print("Not found.")
    end
end

-- Helper for single hash lookup (unchanged, already uses hash_search)
local function hash_search(word)
    local sql = "SELECT word_hash FROM dictionary WHERE word = '" .. escape(word) .. "' LIMIT 1"
    local row = query_one(sql)
    if row and row.word_hash then
        return row.word_hash
    end
    return nil
end

-- Modified fuzzy_and_prefix_wrapper to respect output_hash
local function fuzzy_and_prefix_wrapper(query, no_fuzzy)
    local where = "word LIKE '" .. escape(query) .. "%'"
    where = add_exclusion(where)
    local sql = string.format("SELECT word, word_hash FROM dictionary WHERE %s LIMIT %d", where, MAX_RESULTS)
    local prefix_rows = query_rows(sql)
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
    local row = query_one(sql)
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
-- REPL (modified to include show-hash toggle)
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
-- Parse command line (modified to include --show-hash)
-- ----------------------------------------------------------------------
local function show_usage()
    print([[
Usage:
  lua latin.lua                      → interactive REPL
  lua latin.lua --limit N "word"     → set limit to N for that search
  lua latin.lua "word"               → exact + prefix + fuzzy (default)
  lua latin.lua --exact "word"       → only exact match
  lua latin.lua --no-fuzzy "word"    → exact + prefix (no fuzzy)
  lua latin.lua --prefix "pref"      → list words starting with 'pref'
  lua latin.lua --fuzzy "word"       → fuzzy search only (Levenshtein)
  lua latin.lua --trigram "word"     → trigram similarity search (Jaccard)
  lua latin.lua --def "text"         → search inside definitions
  lua latin.lua --html "word"        → output raw HTML for that word
  lua latin.lua --hash "word"        → output the word_hash for the exact word (single)
  lua latin.lua --show-hash          → show word_hash instead of word/definition for any search
  lua latin.lua --hash-file file     → output word_hashes for each word in file (one per line)
  lua latin.lua --exclude-bad        → exclude entries with the problematic content_hash
]])
end

local function main(args)
    -- check that the table exists
    local row = query_one("SELECT name FROM sqlite_master WHERE type='table' AND name='dictionary'")
    if not row then
        print("Error: 'dictionary' table not found.")
        os.exit(1)
    end

    local limit = MAX_RESULTS
    local no_fuzzy = false
    local exact_mode = false
    local show_hash_mode = false   -- NEW: global flag
    local new_args = {}
    local i = 1
    while i <= #args do
        if args[i] == "--limit" and i+1 <= #args then
            local n = tonumber(args[i+1])
            if n and n >= 0 then
                limit = n
            else
                print("Invalid --limit value. Using default " .. MAX_RESULTS)
            end
            i = i + 2
        elseif args[i] == "--no-fuzzy" then
            no_fuzzy = true
            i = i + 1
        elseif args[i] == "--exact" then
            exact_mode = true
            i = i + 1
        elseif args[i] == "--exclude-bad" then
            exclude_bad = true
            i = i + 1
        elseif args[i] == "--show-hash" then
            show_hash_mode = true
            output_hash = true   -- enable global hash output
            i = i + 1
        elseif args[i] == "--hash" and i+1 <= #args then
            -- single hash lookup (overrides any other mode, exits)
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

    if #new_args == 0 then
        repl()
    elseif new_args[1] == "--prefix" and #new_args >= 2 then
        prefix_search(new_args[2])
    elseif new_args[1] == "--fuzzy" and #new_args >= 2 then
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
    elseif new_args[1] == "--trigram" and #new_args >= 2 then
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
