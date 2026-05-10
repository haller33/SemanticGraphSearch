#!/usr/bin/env sh

# Configuration limits (same as before)
LIMIT_FUZZY=8
LIMIT_PREFIX=4
LIMIT_DEF=3

# Function to clean a word: remove leading/trailing non‑alphanumeric characters
# but keep internal punctuation and special characters.
clean_word() {
    echo "$1" | sed 's/^[^a-zA-Z0-9]*//; s/[^a-zA-Z0-9]*$//'
}

# Function to run a single search in background
run_search() {
    local limit="$1"
    local mode="$2"
    local word="$3"
    local logfile="/tmp/semantic_${mode}_${word}.log"
    nohup sh -c "lua ./semantic-exp-nal.lua --limit ${limit} --to-narsese --${mode} \"${word}\" | python3 narsese2json.py | uv run --with requests python send2graph.py" > "$logfile" 2>&1 &
}

# Main: accept phrase as arguments or from stdin
if [ $# -eq 0 ]; then
    # Read from stdin if no arguments
    read -r phrase
else
    phrase="$*"
fi

# Split phrase into words (simple space separation)
for raw_word in $phrase; do
    # Clean the word
    cleaned=$(clean_word "$raw_word")
    # Skip empty or very short (optional)
    if [ -z "$cleaned" ] || [ ${#cleaned} -lt 2 ]; then
        continue
    fi
    echo "Processing word: '$cleaned' (original: '$raw_word')"

    # Launch three searches in background
    run_search "$LIMIT_FUZZY"   "fuzzy"   "$cleaned"
    run_search "$LIMIT_PREFIX"  "prefix"  "$cleaned"
    run_search "$LIMIT_DEF"     "def"     "$cleaned"
done

wait   # optional: wait for all background jobs to finish
echo "All searches launched."
