# Semantic.lua - Unified Fuzzy Search Strategies

## Overview

The refactored `semantic.lua` unifies three different fuzzy search strategies into a single, parametrized system. All strategies can be configured through top-level constants, making it easy to experiment with different approaches without code changes.

## Configuration Parameters

At the top of `semantic.lua`, you'll find these configuration constants:

```lua
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
```

## Search Strategies

### 1. Single Search (`SEARCH_MODE = "single"`)

**What it does:** Simple fuzzy search using the input word as-is.

**How to use:**
```lua
local SEARCH_MODE = "single"
local NORMALIZE_ACCENTS = false  -- or true, doesn't matter much
```

**Good for:** Fast searches when you want a baseline or don't have accented text issues.

**Example:**
- Input: `amor`
- Searches: dictionary for words similar to "amor"
- Returns: Top 5 matches by fuzzy score

---

### 2. Dual Merge Search (`SEARCH_MODE = "dual_merge"`)

**What it does:** Performs TWO independent searches:
1. Search using the original word (with accents if any)
2. Search using the normalized word (accents removed)
3. Merges results, keeping the best score for each word

**How to use:**
```lua
local SEARCH_MODE = "dual_merge"
local NORMALIZE_ACCENTS = true
local DUAL_SEARCH_RESULTS_MULTIPLIER = 2  -- Adjust for quality vs speed
```

**Good for:** 
- Handling Portuguese/Latin text with or without accents
- Getting more robust results that work regardless of accent input
- Finding words that might have accent variations

**Example:**
- Input: `amór` (with accent) + normalized `amor` (without)
- Search 1: Finds "amor", "amorous", "damora" matching "amór"
- Search 2: Finds "amor", "amour", "amours" matching "amor"
- Merged result: Best matches from both searches, deduplicated

**Parameters:**
- `DUAL_SEARCH_RESULTS_MULTIPLIER`: Before merging, fetch N×MAX_RESULTS from each search
  - `1`: Lower quality (may miss good matches), faster
  - `2`: Recommended (good balance)
  - `3+`: Higher quality (more thorough), slower

---

### 3. Prefix Search (`SEARCH_MODE = "prefix"`)

**What it does:** Prioritizes words that START with the input, with fuzzy scoring for prefix mismatches.

**How to use:**
```lua
local SEARCH_MODE = "prefix"
local NORMALIZE_ACCENTS = true
```

**Good for:**
- Autocomplete-like behavior
- Finding word families (e.g., "am" → "amor", "amicus", "amabilis")
- Quick filtering when you know the word start

**Example:**
- Input: `am`
- Returns: "amor", "amabilis", "amicus" (all start with "am")
- Then scored: "amor" (perfect match) < "amabilis" (1 char diff) < "amicus" (1 char diff)

---

## Scoring System

### Fuzzy Score (Levenshtein-based)

Returns a normalized value from 0 to 1:
- **0.0** = Perfect match
- **0.1-0.3** = Very good match
- **0.3-0.45** = Good match (below threshold)
- **> 0.45** = Rejected

The score is: `levenshtein_distance / max(length(word), length(target))`

### Prefix Score

Used only in prefix search mode:
- **0.0** = Perfect prefix match
- **0.1+** = Prefix mismatch by N characters

---

## Accent Normalization

When `NORMALIZE_ACCENTS = true`, the system maps:

```
Lowercase:
á,à,â,ã,ä → a
é,è,ê,ë → e
í,ì,î,ï → i
ó,ò,ô,õ,ö → o
ú,ù,û,ü → u
ç → c
ñ → n

Uppercase: Same mappings (all to lowercase)
```

This is crucial for Portuguese/Latin text where accents vary.

---

## Code Structure

### Core Functions

| Function | Purpose |
|----------|---------|
| `normalize_accents(s)` | Convert accented chars to ASCII equivalents |
| `clean_word(word)` | Trim, remove punctuation, lowercase, return (original, normalized) |
| `levenshtein(s, t)` | Calculate edit distance |
| `fuzzy_score(word, target)` | Normalized Levenshtein score (0=best, 1=worst) |
| `prefix_score(word, target)` | Prefix-matching score |
| `fuzzy_search_single(input, max_results)` | Single search strategy |
| `fuzzy_search_dual_merge(original, normalized, max_results)` | Dual search with merge |
| `fuzzy_search_prefix(input, max_results)` | Prefix search strategy |
| `fuzzy_search(original, normalized, max_results)` | Dispatcher (chooses strategy based on SEARCH_MODE) |

### Database Functions

| Function | Purpose |
|----------|---------|
| `query_all(db, sql)` | Execute SQL, return all rows |
| `query_one(db, sql)` | Execute SQL, return first row |
| `get_narsese_for_word(word)` | Retrieve pre-translated Narsese using word hash |

### Processing Functions

| Function | Purpose |
|----------|---------|
| `clean_narsese(raw)` | Remove markdown backticks, keep only lines with `<>` |
| `fallback_narsese(word)` | Generate simple `<word --> latinWord>.` |
| `nal_to_json(nal_string)` | Convert Narsese to JSON via narsese2json.py |
| `json_to_graph(json_data)` | Send JSON to graph visualizer |
| `process_phrase(phrase)` | Main pipeline orchestrator |

---

## Usage Examples

### Example 1: Basic Single Search
```bash
./semantic.lua "amor"
```
Edit `semantic.lua` to set:
```lua
local SEARCH_MODE = "single"
local NORMALIZE_ACCENTS = false
```

### Example 2: Dual Search with Accents
```bash
./semantic.lua "amór vitae"
```
Set:
```lua
local SEARCH_MODE = "dual_merge"
local NORMALIZE_ACCENTS = true
local DUAL_SEARCH_RESULTS_MULTIPLIER = 2
```

### Example 3: Prefix-based Autocomplete
```bash
./semantic.lua "am"
```
Set:
```lua
local SEARCH_MODE = "prefix"
local NORMALIZE_ACCENTS = true
```

---

## How Dual Merge Works

### Step 1: Two Independent Searches
```
Original word: "amór"
Normalized word: "amor"

Search 1 (original "amór"):
  Searching dictionary for words fuzzy-similar to "amór"
  Results: [amor (0.1), amour (0.2), amorph (0.3)]

Search 2 (normalized "amor"):
  Searching dictionary for words fuzzy-similar to "amor"
  Results: [amor (0.0), amorous (0.15), amours (0.2)]
```

### Step 2: Merge by Word
```
Merged map:
  amor → 0.0 (best from Search 2)
  amour → 0.2 (from Search 1)
  amorph → 0.3 (from Search 1)
  amorous → 0.15 (from Search 2)
  amours → 0.2 (from Search 1)
```

### Step 3: Sort and Limit
```
Final result (top 5):
  [1] amor (0.0)
  [2] amorous (0.15)
  [3] amour (0.2)
  [4] amours (0.2)
  [5] amorph (0.3)
```

---

## Performance Tuning

### For Speed
```lua
local SEARCH_MODE = "single"
local NORMALIZE_ACCENTS = false
local DUAL_SEARCH_RESULTS_MULTIPLIER = 1
local FUZZY_SCORE_THRESHOLD = 0.5  -- Reject more matches
```

### For Quality
```lua
local SEARCH_MODE = "dual_merge"
local NORMALIZE_ACCENTS = true
local DUAL_SEARCH_RESULTS_MULTIPLIER = 3
local FUZZY_SCORE_THRESHOLD = 0.4  -- Accept more matches
```

### For Autocomplete
```lua
local SEARCH_MODE = "prefix"
local NORMALIZE_ACCENTS = true
local FUZZY_SCORE_THRESHOLD = 0.3
```

---

## Output Example

```
========== PROCESSING PHRASE ==========
Original: amor est vitae
Search mode: dual_merge
Normalize accents: true
========================================

--- WORD: 'amor' ---
  Original: 'amor'
  Normalized: 'amor'
  Found 5 matches:

  [1/5] Match: 'amor' (score: 0.0000)
        Status: Using pre-translated Narsese
        NAL:
          <amor --> latinWord>.
        JSON preview: {"nodes": [...], "edges": [...]}
        Graph response: OK

  [2/5] Match: 'amour' (score: 0.2000)
        Status: Using fallback Narsese
        ...

--- WORD: 'est' ---
  Original: 'est'
  Normalized: 'est'
  Found 3 matches:
  ...

========== PROCESSING COMPLETE ==========
```

---

## Tips & Tricks

1. **For Portuguese text with accents**: Always use `NORMALIZE_ACCENTS = true` with `dual_merge` mode
2. **For autocomplete**: Use `prefix` mode with lower threshold (0.3-0.35)
3. **For robustness**: Use `dual_merge` with `DUAL_SEARCH_RESULTS_MULTIPLIER = 2` or `3`
4. **For speed**: Use `single` mode with higher threshold (0.5+)
5. **Debug**: The output shows normalization, making it easy to understand why a match was found

---

## Future Enhancements

Potential additions to the parametrized system:

- Phonetic similarity (Soundex/Metaphone for Latin)
- Definition weight adjustment
- Word frequency boost
- Synonym expansion using definitions
- Caching for repeated searches
- Parallel search (original + normalized simultaneously)

