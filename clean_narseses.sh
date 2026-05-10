#!/usr/bin/env sh

sed 's/`//g' |
    sed 's/`//g' |
    sed 's/```//g' |
    sed 's/^/</g' |
    sed 's/$/>./g' |
    sed 's/<</</g' |
    sed 's/>.>./>./g' |
    sed 's/>. </>.\n</g' |
    sed 's/<>.//g' |

    sed 's/<narsese>.//g' |
    grep -v '^$'
    
