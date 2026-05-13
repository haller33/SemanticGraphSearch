#!/usr/bin/env sh

# Configuration
LIMIT_FUZZY=3
LIMIT_PREFIX=4
LIMIT_DEF=3
MAX_CONCURRENT_WORDS=1          # process up to 1 word simultaneously (adjustable)
JOBS_PER_WORD=3                 # (fuzzy, prefix, def) – used to track total jobs

USE_FUZZY_C_LIBRARY=1

USE_MORPHOLOGY=1

TMP_PID_FILE="/tmp/semantic_pids.$$"  # unique per script run

# Plain NAL mode flag (default: false)
PLAIN_NAL=0

# Parse flags
while [ "$1" = "--plain-nal" ]; do
    PLAIN_NAL=1
    shift
done

while [ "$1" = "--limit" ]; do
    
    LIMIT_FUZZY="$2"
    LIMIT_PREFIX="$2"
    LIMIT_DEF="$2"
    shift
done

# Clean word: remove leading/trailing non-alphanumeric
clean_word() {
    echo "$1" | sed 's/^[^a-zA-Z0-9]*//; s/[^a-zA-Z0-9]*$//'
}

run_morphology() {

    local word=$1

    # MORPHLIB=morpheus-perseids/stemlib morpheus-perseids/bin/morpheus -L 'Sperne repugnando tibi tu contrarius esse: Conveniet nulli, qui secum dissidet ipse.' >> morphology_extended.xml
    # cat morphology.xml |
    #    uv run python morphology_to_nal.py |
    #    ../OpenNARS-for-Applications/NAR shell |
    #    sh extract_derived.sh |
    #    python3 narsese2json.v2.py --tag derived |
    #    uv run --with requests python send2graph.py --color "#ff0000"
    
}

# Launch a single search – in plain mode it runs synchronously and prints NAL.
run_search() {
    local limit="$1"
    local mode="$2"
    local word="$3"

    if [ "$PLAIN_NAL" -eq 1 ]; then
        # Plain NAL mode: run in foreground, output to stdout
        if [ "$USE_FUZZY_C_LIBRARY" -eq 1 ]; then
            lua ./semantic-exp-nal.lua --fuzzy-c --limit "${limit}" --to-narsese "--${mode}" "${word}"
        else 
            lua ./semantic-exp-nal.lua --limit "${limit}" --to-narsese "--${mode}" "${word}"
        fi 
    else
        # Graph mode: background pipeline
        if [ "$USE_FUZZY_C_LIBRARY" -eq 1 ]; then
            nohup sh -c "lua ./semantic-exp-nal.lua --fuzzy-c --limit ${limit} --to-narsese --${mode} \"${word}\" | python3 narsese2json.v2.py --tag input | uv run --with requests python send2graph.py" > "/dev/null" 2>&1 &
            local pid=$!
            echo "$pid" >> "$TMP_PID_FILE"
        else
            nohup sh -c "lua ./semantic-exp-nal.lua --limit ${limit} --to-narsese --${mode} \"${word}\" | python3 narsese2json.v2.py --tag input | uv run --with requests python send2graph.py" > "/dev/null" 2>&1 &
            local pid=$!
            echo "$pid" >> "$TMP_PID_FILE"
        fi
    fi
}

# Wait until number of active background jobs is less than max
wait_if_busy() {
    local max_total_jobs=$(( MAX_CONCURRENT_WORDS * JOBS_PER_WORD ))
    while true; do
        local active=0
        for pid in $(cat "$TMP_PID_FILE" 2>/dev/null); do
            if kill -0 "$pid" 2>/dev/null; then
                active=$(( active + 1 ))
            fi
        done
        # Clean dead PIDs from file
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

# Main: accept phrase from arguments or stdin (after removing flags)
if [ $# -eq 0 ]; then
    read -r phrase
else
    phrase="$*"
fi

# Clean up PID file on exit
trap 'rm -f "$TMP_PID_FILE"' EXIT

# Process each word
word_count=0
for raw_word in $phrase; do
    cleaned=$(clean_word "$raw_word")
    [ -z "$cleaned" ] || [ ${#cleaned} -lt 2 ] && continue

    if [ "$PLAIN_NAL" -eq 0 ]; then
        # Graph mode: concurrency control
        word_count=$(( word_count + 1 ))
        if [ $word_count -gt $MAX_CONCURRENT_WORDS ]; then
            wait_if_busy
            word_count=1
        fi
    fi

    if [ "$PLAIN_NAL" -eq 1 ]; then
        # echo "=== NAL for word: $cleaned (mode: prefix) ==="
        run_search "$LIMIT_PREFIX" "prefix" "$cleaned"
        # echo "=== NAL for word: $cleaned (mode: definition) ==="
        run_search "$LIMIT_DEF"    "def"    "$cleaned"
        # echo "=== NAL for word: $cleaned (mode: fuzzy) ==="
        run_search "$LIMIT_FUZZY"  "fuzzy"  "$cleaned"
    else
        echo "Processing word: '$cleaned' (original: '$raw_word')"
        run_search "$LIMIT_FUZZY"  "fuzzy"  "$cleaned"
        run_search "$LIMIT_PREFIX" "prefix" "$cleaned"
        run_search "$LIMIT_DEF"    "def"    "$cleaned"
    fi

    if [ "{USE_MORPHOLOGY}" -eq 1 ]; then
        run_morphology "$cleaned"
    fi
done

if [ "$PLAIN_NAL" -eq 0 ]; then
    wait
    echo "All searches launched and completed."
# else
    # echo "All NAL statements printed."
fi
