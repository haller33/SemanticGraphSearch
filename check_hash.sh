#!/usr/bin/env sh

sqlite3 latin_to_narsese/narseses_latim_portugues.db "select narsese_output from translations where word_hash = '$1'"
