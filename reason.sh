#!/usr/bin/env sh


sh semantic.sh --plain-nal $1 |  sh clean_narseses.sh | ../OpenNARS-for-Applications/NAR shell |
 sh extract_nal.sh | python3 narsese2json.py | uv run --with requests python send2graph.py
