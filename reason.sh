#!/usr/bin/env sh

# sh semantic.sh --plain-nal $1 | sh clean_narseses.sh |
#    ./../OpenNARS-for-Applications/NAR shell | sh extract_derived.sh |
#    python3 narsese2json.py | uv run --with requests python send2graph.py 


sh semantic.sh --plain-nal "$1" | sh clean_narseses.sh >> input.nal
# touch input.nal derived.nal

# tail -f input.nal | python3 narsese2json.py | uv run --with requests python send2graph.py &

# tail -f input.nal | ./../OpenNARS-for-Applications/NAR shell >> derived.nal &

# tail -f derived.nal | sh extract_derived.sh | python3 narsese2json.py | uv run --with requests python send2graph.py --color "#ff0000" & 

  
# sh semantic.sh --plain-nal $1 |  sh clean_narseses.sh >> input.nal

echo "done"
# 
