#!/usr/bin/env sh

echo '###########################################'

sh semantic.sh --plain-nal $1 | sh clean_narseses.sh |  ./OpenNARS-for-Applications/NAR shell 

echo '###########################################'
