#!/usr/bin/env sh

grep -v -e 'Input: ' -e 'Selected: ' | 
    grep '^Derived:' |
    sed 's/^Derived: //' |
    sed 's/\. Priority=.*/>./' |
    grep -v '^$'

# sed 's/>. Priority=.*/>./g' |
#    head -n -18 |
#    grep 'Derived: ' |
#    cut -d':' -f2- |
#    grep -v '^$'
