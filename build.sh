
mkdir -p bin

gcc -O2 -o ./bin/filter_derived ./src/c/filter_derived.c
gcc -O2 -o ./bin/send2graph ./src/c/send2graph.c -lcurl -lcjson
gcc -O2 -o ./bin/narsese2json ./src/c/narsese2json.c -lm
