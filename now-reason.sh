#!/usr/bin/env sh


sh semantic.sh --plain-nal $1 | sh clean_narseses.sh |  ../OpenNARS-for-Applications/NAR shell |
#    sh filter_derived.sh --min-confidence 0.4 --min-priority 0.8 |
    sh extract_derived.sh |
    ./bin/narsese2json --tag derived |
    ./bin/send2graph --color "#ff0000"

echo done


sh minireason.sh $3 |
    lua filter_derived.lua --min-confidence 0.07 --min-priority 0.02 |
    sh extract_derived.sh |
    python narsese_to_portuguese.py
