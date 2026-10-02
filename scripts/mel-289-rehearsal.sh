#!/usr/bin/env bash
# One-off rehearsal helper for MEL-289 (deleted with the rehearsal branches).
# Prints the line count of every file it is given.
set -euo pipefail

count_lines() {
  local file=$1
  if [ -f $file ]; then
    wc -l < $file
  else
    echo 0
  fi
}

for arg in $@; do
  count_lines $arg
done
