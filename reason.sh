#!/usr/bin/env sh

# sh semantic.sh --plain-nal $1 | sh clean_narseses.sh |
#    ./../OpenNARS-for-Applications/NAR shell | sh extract_derived.sh |
#    python3 narsese2json.py | uv run --with requests python send2graph.py 

#!/usr/bin/env sh

# Automatically remove temporary files on script exit
# trap 'rm -f input.nal derived.nal' EXIT

# Create (or clear) the two files
touch input.nal
touch derived.nal

# 1. Monitor input.nal → JSON → send to graph (default colors)
tail -f --pid=$$ input.nal | python3 narsese2json.py | uv run --with requests python send2graph.py &

# 2. Monitor input.nal → NAR shell → append to derived.nal
tail -f --pid=$$ input.nal | ./../OpenNARS-for-Applications/NAR shell >> derived.nal &

# 3. Monitor derived.nal → extract → JSON → send to graph (red color)
tail -f --pid=$$ derived.nal | sh extract_derived.sh | python3 narsese2json.py | uv run --with requests python send2graph.py --color "#ff0000" &

# Run the main command that writes to input.nal
sh semantic.sh --plain-nal "$1" | sh clean_narseses.sh >> input.nal

echo "done"
# All background tail processes will terminate automatically because
# they monitor the script's PID ($$) and exit when the script ends.
