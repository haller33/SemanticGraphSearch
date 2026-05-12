#!/usr/bin/env sh

# filter_derived.sh - filter Derived lines by priority, frequency, and confidence
# Usage: ./filter_derived.sh [--min-priority P] [--min-frequency F] [--min-confidence C]
# Defaults: all thresholds = 0 (no filtering)

MIN_PRIORITY=0
MIN_FREQUENCY=0
MIN_CONFIDENCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-priority)
            MIN_PRIORITY="$2"
            shift 2
            ;;
        --min-frequency)
            MIN_FREQUENCY="$2"
            shift 2
            ;;
        --min-confidence)
            MIN_CONFIDENCE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

awk -v min_pri="$MIN_PRIORITY" -v min_freq="$MIN_FREQUENCY" -v min_conf="$MIN_CONFIDENCE" '
/^Derived:/ {
    # Extract Priority=number (may be in exponential notation, e.g. 0.301667)
    if (match($0, /Priority=([0-9.eE+-]+)/, pri_arr)) {
        pri = pri_arr[1] + 0
    } else {
        pri = 0
    }
    # Extract Truth: frequency=number, confidence=number
    if (match($0, /Truth: frequency=([0-9.eE+-]+), confidence=([0-9.eE+-]+)/, truth_arr)) {
        freq = truth_arr[1] + 0
        conf = truth_arr[2] + 0
    } else {
        freq = 0
        conf = 0
    }
    if (pri >= min_pri && freq >= min_freq && conf >= min_conf) {
        print
    }
    next
}
{ print }   # pass all non-Derived lines through unchanged
'
