#!/bin/bash
# Draait alle shell-tests. Gebruik: bash tests/shell/run-all.sh
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$dir"/test_*.sh; do
  echo "== $(basename "$t")"
  /bin/bash "$t" || failed=$((failed + 1))
done
if [ "$failed" -eq 0 ]; then echo "Alle shell-tests geslaagd."; else echo "$failed test(s) mislukt."; exit 1; fi
