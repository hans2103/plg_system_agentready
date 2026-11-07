#!/bin/bash
# Test voor .githooks/commit-msg. Gebruik: bash tests/shell/test_commit_msg_hook.sh
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo/.githooks/commit-msg"
failed=0

check() { # bericht verwachte-exitcode
  local f rc
  f=$(mktemp); printf '%s\n' "$1" > "$f"
  "$hook" "$f" > /dev/null 2>&1; rc=$?
  rm -f "$f"
  if [ "$rc" -eq "$2" ]; then echo "ok:   '$1' -> $rc"; else echo "FAIL: '$1' gaf $rc, verwachtte $2"; failed=1; fi
}

check 'feat(kalender): #12 nieuwe functie' 0
check 'fix: #5 afronding' 0
check 'chore: #000 opruimen' 0
check 'Merge pull request #8 from x/y' 0
check 'chore(release): versie bijgewerkt naar 26.39.0' 0
check 'feat: nieuwe functie zonder issue' 1
check 'fix: issue zonder hekje 12' 1

[ "$failed" -eq 0 ] && echo "Alle controles geslaagd." || exit 1
