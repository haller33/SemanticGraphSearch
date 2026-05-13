#!/usr/bin/env sh


sh semantic.sh --plain-nal $1 | sh clean_narseses.sh |  ../OpenNARS-for-Applications/NAR shell |
#    sh filter_derived.sh --min-confidence 0.4 --min-priority 0.8 |
    sh extract_derived.sh | python3 narsese2json.v2.py --tag derived |
    uv run --with requests python send2graph.py --color "#ff0000"

echo done

