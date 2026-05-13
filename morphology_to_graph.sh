#!/usr/bin/env sh

PLAIN_NAL=0

# Parse flags
while [ "$1" = "--plain-nal" ]; do
    PLAIN_NAL=1
    shift
done

if [ "$PLAIN_NAL" -eq 1 ]; then
    MORPHLIB=morpheus-perseids/stemlib morpheus-perseids/bin/morpheus -L "$1" |
        uv run python morphology_to_nal.py
else
    MORPHLIB=morpheus-perseids/stemlib morpheus-perseids/bin/morpheus -L "$1" |
        uv run python morphology_to_nal.py |
        python3 narsese2json.v3.py --tag input |
        uv run --with requests python send2graph.py
fi 
