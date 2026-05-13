#!/usr/bin/env sh
# This pipeline processes a NARS (Non-Axiomatic Reasoning System) input string
# using several tools to filter derived beliefs and translate the result to Portuguese.
#
# Arguments:
#   $1 – Minimum confidence thresholds (e.g., 0.07)
#   $2 - Minimum priority thresholds (e.g., 0.02)
#   $3 – Input string in Narsese or natural language (e.g., a Latin phrase)
#
# Steps:
# 1. minireason.sh  – Runs the reasoner on the input ($3)
# 2. filter_derived.lua – Filters derived beliefs, keeping only those with
#    confidence >= $1 and priority >= $2
# 3. extract_derived.sh – Extracts the relevant derived statements
# 4. narsese_to_portuguese.py – Converts the final Narsese output into Portuguese
#
# Example usage in a script:
#   ./minireason_portuguese.sh 0.07 0.02 "plus vigila semper nec somino deditus eius"
#   ./minireason_portuguese.sh --buff 0.07 0.02 "plus vigila semper nec somino deditus eius"

# Reason on input $3, filter derived beliefs by confidence/priority $1 and $2, extract, then translate to 'Portuguese'

BUFFER=0

PROMPT=$3

while [ "$1" = "--buff" ]; do

    BUFFER=1
    PROMPT=$4
    shift
done

echo $PROMPT

if [ "$BUFFER" -eq 1 ]; then

    HASH=$(echo "${PROMPT}" | sha256sum | cut -d' ' -f1)
    FILE_NAME_NOW="buff.${HASH}.nal"
    FILE_PATH="/tmp/${FILE_NAME_NOW}"

    if [ ! -e "${FILE_PATH}"  ]; then 
        sh minireason.sh "${PROMPT}" > "${FILE_PATH}"
    fi
    
    cat "${FILE_PATH}" |
        lua filter_derived.lua --min-confidence $1 --min-priority $2 |
        sh extract_derived.sh |
        python narsese_to_portuguese.py
else

    sh minireason.sh "${PROMPT}" |
        lua filter_derived.lua --min-confidence $1 --min-priority $2 |
        sh extract_derived.sh |
        python narsese_to_portuguese.py

fi
