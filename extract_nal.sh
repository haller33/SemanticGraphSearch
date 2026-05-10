#!/usr/bin/env sh

sed 's/>. Priority=.*/>./g' |
    head -n -18 |
    cut -d':' -f2-|
    grep -v '^$'
