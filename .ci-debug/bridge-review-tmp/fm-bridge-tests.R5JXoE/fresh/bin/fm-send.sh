#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$(dirname "$0")/sent.log"
