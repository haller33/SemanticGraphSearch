#!/usr/bin/env bash

touch input.nal
touch derived.nal


# In a dedicated terminal
tail -f input.nal | python3 narsese2json.v2.py --tag input | uv run --with requests python send2graph.py &
tail -f input.nal | ../OpenNARS-for-Applications/NAR shell >> derived.nal &
tail -f derived.nal |
    sh filter_derived.sh --min-confidence 0.4 --min-priority 0.8 |
    sh extract_derived.sh | python3 narsese2json.v2.py --tag derived |
    uv run --with requests python send2graph.py --color "#ff0000" &
