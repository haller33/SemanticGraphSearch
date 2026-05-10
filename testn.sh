#!/usr/bin/env sh

for i in $(lua semantic-exp.lua --limit 10  --show-hash --prefix amo | grep -v "Hash"); do
    sqlite3 latin_to_narsese/narseses_latim_portugues.db "select narsese_output from translations where word_hash = '$i'" |
        sh clean_narseses.sh  ; done |
    ../OpenNARS-for-Applications/NAR shell
