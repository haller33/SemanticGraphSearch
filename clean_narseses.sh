#!/usr/bin/env sh

# sed 's/`//g' |
#     sed 's/`//g' |
#     sed 's/```//g' |
#     sed 's/^/</g' |
#     sed 's/$/>./g' |
#     sed 's/<</</g' |
#     sed 's/>.>./>./g' |
#     sed 's/>. </>.\n</g' |
#     sed 's/<>.//g' |
# 
#     sed 's/<narsese>.//g' |
#     grep -v '^$'


#!/usr/bin/env sh
# Clean Narsese with line buffering

stdbuf -oL sed 's/`//g' |
    stdbuf -oL sed 's/`//g' |
    stdbuf -oL sed 's/```//g' |
    stdbuf -oL sed 's/^/</g' |
    stdbuf -oL sed 's/$/>./g' |
    stdbuf -oL sed 's/<</</g' |
    stdbuf -oL sed 's/>.>./>./g' |
    stdbuf -oL sed 's/>. </>.\n</g' |
    stdbuf -oL sed 's/<>.//g' |
    stdbuf -oL sed 's/<narsese>.//g' |
    stdbuf -oL grep --line-buffered -v '^$'
