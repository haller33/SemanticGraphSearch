#!/usr/bin/env sh

stdbuf -oL grep -v -e 'Input: ' -e 'Selected: ' | 
    stdbuf -oL grep '^Derived:' |
    stdbuf -oL sed 's/^Derived: //' |
    stdbuf -oL sed 's/\. Priority=.*/>./' |
    stdbuf -oL grep -v '^$'

# sed 's/>. Priority=.*/>./g' |
#    head -n -18 |
#    grep 'Derived: ' |
#    cut -d':' -f2- |
#    grep -v '^$'
