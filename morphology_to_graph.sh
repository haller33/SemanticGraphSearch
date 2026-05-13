#!/usr/bin/env sh

MORPHLIB=morpheus-perseids/stemlib morpheus-perseids/bin/morpheus -L "$1" |
        uv run python morphology_to_nal.py # |
#        python3 narsese2json.v2.py --tag input # |
#        uv run --with requests python send2graph.py
