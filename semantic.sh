#!/usr/bin/env sh

# Configuration
LIMIT_FUZZY=3
LIMIT_PREFIX=4
LIMIT_DEF=3
MAX_CONCURRENT_WORDS=1          # process up to 3 words simultaneously
JOBS_PER_WORD=3                 # (fuzzy, prefix, def) – used to track total jobs

TMP_PID_FILE="/tmp/semantic_pids.$$"  # unique per script run

# Clean word: remove leading/trailing non-alphanumeric
clean_word() {
    echo "$1" | sed 's/^[^a-zA-Z0-9]*//; s/[^a-zA-Z0-9]*$//'
}

# Launch a single search in background, record its PID
run_search() {
    local limit="$1"
    local mode="$2"
    local word="$3"
    nohup sh -c "lua ./semantic-exp-nal.lua --limit ${limit} --to-narsese --${mode} \"${word}\" | python3 narsese2json.py | uv run --with requests python send2graph.py" > "/dev/null" 2>&1 &
    local pid=$!
    echo "$pid" >> "$TMP_PID_FILE"
}

# Wait until number of active background jobs is less than max
wait_if_busy() {
    local max_total_jobs=$(( MAX_CONCURRENT_WORDS * JOBS_PER_WORD ))
    while true; do
        # Count how many PIDs in TMP_PID_FILE are still running
        local active=0
        for pid in $(cat "$TMP_PID_FILE" 2>/dev/null); do
            if kill -0 "$pid" 2>/dev/null; then
                active=$(( active + 1 ))
            fi
        done
        # Remove dead PIDs from file (optional, for cleanliness)
        local new_pids=""
        for pid in $(cat "$TMP_PID_FILE" 2>/dev/null); do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids="$new_pids $pid"
            fi
        done
        echo "$new_pids" | tr ' ' '\n' | grep -v '^$' > "$TMP_PID_FILE" 2>/dev/null

        if [ "$active" -lt "$max_total_jobs" ]; then
            break
        fi
        sleep 1
    done
}

# Main: accept phrase from arguments or stdin
if [ $# -eq 0 ]; then
    read -r phrase
else
    phrase="$*"
fi

# Clean up PID file on exit
trap 'rm -f "$TMP_PID_FILE"' EXIT

# Process each word, but limit concurrency
word_count=0
for raw_word in $phrase; do
    cleaned=$(clean_word "$raw_word")
    [ -z "$cleaned" ] || [ ${#cleaned} -lt 2 ] && continue

    # Wait if we already have MAX_CONCURRENT_WORDS words processing
    word_count=$(( word_count + 1 ))
    if [ $word_count -gt $MAX_CONCURRENT_WORDS ]; then
        wait_if_busy
        word_count=1   # reset after waiting (one slot freed)
    fi

    echo "Processing word: '$cleaned' (original: '$raw_word')"
    run_search "$LIMIT_FUZZY"  "fuzzy"  "$cleaned"
    run_search "$LIMIT_PREFIX" "prefix" "$cleaned"
    run_search "$LIMIT_DEF"    "def"    "$cleaned"
done

# Wait for all remaining background jobs to finish
wait
echo "All searches launched and completed."
