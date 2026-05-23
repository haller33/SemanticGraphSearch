#!/usr/bin/env sh

stdbuf -oL sed 's/>. Priority=.*/>./g' |
    stdbuf -oL head -n -18 |
    stdbuf -oL cut -d':' -f2-|
    stdbuf -oL grep -v '^$'
